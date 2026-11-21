/// WebDAV 同步的合并引擎: 历史记录/图片收藏/本地收藏/阅读位置/设置。
///
/// 纯 Dart (只用 dart:io + sqlite3), 不 import Flutter, 便于
/// $  dart run tool/sync_merge_smoke.dart 造真实 sqlite 文件跑断言。
///
/// 约定:
/// - 历史表按 target 去重, 取 time 更晚的一行; readEpisode 取并集。
/// - image_favorites 与本地收藏表没有可靠修改时间的地方, 分别补 updatedAt 列 /
///   tombstone 表, 冲突时"更晚修改者胜、删除者胜"。
/// - 本地收藏的删除墓碑带 folder, 避免一个收藏夹里删掉的作品在另一个收藏夹里被误删。
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'sync_protocol.dart';

export 'sync_protocol.dart';

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

/// 一条「ATTACH 合并」阶段日志: (阶段名, 距本次合并开始的毫秒数)
typedef SyncMergeLog = void Function(String phase, int elapsedMs);

/// ATTACH 远端库用的 schema 别名
const String _remoteSchema = 'remote';

/// 拼 SQL 字符串字面量, 只需要处理文件路径里可能出现的单引号
String _sqlString(String value) => "'${value.replaceAll("'", "''")}'";

/// 在本地已经打开的连接 [db] 上 ATTACH 远端库文件, 返回是否成功。
///
/// 远端库是快照解压到缓存目录的一次性副本, 这里只读不写, 不会关闭 [db],
/// 也不会动用户的远端快照 / 本地数据库文件。
bool _attachRemote(Database db, String remotePath) {
  if (!File(remotePath).existsSync()) {
    return false;
  }
  // 上一次合并如果异常中断导致 DETACH 没跑成功, 别名会被一直占着, 先清掉
  try {
    db.execute('detach database $_remoteSchema;');
  } catch (_) {}
  try {
    db.execute('attach database ${_sqlString(remotePath)} as $_remoteSchema;');
    return true;
  } catch (_) {
    // 不是有效的 sqlite 文件 / 打不开: 当作没有远端数据(旧实现也是空合并),
    // 不能让一个坏快照拖垮整轮同步
    _detachRemote(db);
    return false;
  }
}

/// DETACH 远端库。失败只忽略: 合并结果已经提交, 残留的 attach 下次合并前会清掉
void _detachRemote(Database db) {
  try {
    db.execute('detach database $_remoteSchema;');
  } catch (_) {}
}

void _rollback(Database db) {
  try {
    db.execute('rollback;');
  } catch (_) {}
}

/// ATTACH 出来的远端库的只读入口。
///
/// 所有查询都限定在 `remote.` 这个 schema 上, 底层仍然是 [db] 这一个本地连接,
/// 因此合并期间本地连接不会被关闭或重新打开 (4.10.1 冷启动闪退的根因就是运行时
/// dispose 连接: ImageFavoriteManager 复用 HistoryManager 的 _db, 关掉后再被 UI
/// 查询会踩到已释放的原生句柄)。
class _AttachedRemote {
  final Database db;

  const _AttachedRemote(this.db);

  List<String> tableNames() {
    try {
      return db
          .select(
              "select name from $_remoteSchema.sqlite_master where type='table';")
          .map((row) => row['name'].toString())
          .toList();
    } catch (_) {
      return <String>[];
    }
  }

  bool hasTable(String name) {
    try {
      return db
          .select(
              "select name from $_remoteSchema.sqlite_master where type='table' and name=?;",
              [name])
          .isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Set<String> columns(String table) {
    if (!hasTable(table)) {
      return <String>{};
    }
    try {
      return db
          .select('PRAGMA $_remoteSchema.table_info("$table");')
          .map((row) => row['name'].toString())
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  ResultSet rows(String table) =>
      db.select('select * from $_remoteSchema."$table";');
}

Map<String, dynamic> _rowMap(Row row) => Map<String, dynamic>.from(row);

int _int(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

String _str(dynamic value) => value?.toString() ?? '';

bool _tableExists(Database db, String name) {
  try {
    return db
        .select("select name from sqlite_master where type='table' and name=?",
            [name])
        .isNotEmpty;
  } catch (_) {
    return false;
  }
}

Set<String> _columns(Database db, String table) {
  if (!_tableExists(db, table)) {
    return <String>{};
  }
  try {
    return db
        .select('PRAGMA table_info("$table");')
        .map((row) => row['name'].toString())
        .toSet();
  } catch (_) {
    return <String>{};
  }
}

// ---------------------------------------------------------------------------
// history.db: 历史记录 + 图片收藏
// ---------------------------------------------------------------------------

/// 合并历史记录表与图片收藏表。
///
/// [local] 是调用方**已经打开**的 history.db 连接 (HistoryManager 那一个),
/// 本函数只在它上面 ATTACH 远端库并写本地库, 整个过程不关闭、不重开连接。
/// [remotePath] 是下载快照解压出来的一次性副本, 只读不写。
SyncStats mergeHistoryDatabase({
  required Database local,
  required String remotePath,
  required int nowMs,
  SyncMergeLog? log,
}) {
  final stats = SyncStats();
  final startedAt = DateTime.now();
  int elapsedMs() => DateTime.now().difference(startedAt).inMilliseconds;
  if (!_attachRemote(local, remotePath)) {
    return stats;
  }
  log?.call('ATTACH 远端 history.db', elapsedMs());
  final remote = _AttachedRemote(local);
  try {
    local.execute('begin immediate;');
    try {
      _ensureHistorySchema(local);
      _mergeHistoryTable(local, remote, stats);
      _mergeImageFavorites(local, remote, stats, nowMs);
      local.execute('commit;');
      log?.call('合并事务已提交', elapsedMs());
    } catch (_) {
      _rollback(local);
      rethrow;
    }
  } finally {
    _detachRemote(local);
    log?.call('DETACH 远端 history.db', elapsedMs());
  }
  return stats;
}

void _ensureHistorySchema(Database db) {
  db.execute("""
    create table if not exists history  (
      target text primary key,
      title text,
      subtitle text,
      cover text,
      time int,
      type int,
      ep int,
      page int,
      readEpisode text,
      max_page int
    );
  """);
  if (!_columns(db, 'history').contains('max_page')) {
    db.execute('alter table history add column max_page int;');
  }
  db.execute("""
    create table if not exists image_favorites (
      id TEXT,
      title TEXT NOT NULL,
      cover TEXT NOT NULL,
      ep INTEGER NOT NULL,
      page INTEGER NOT NULL,
      other TEXT NOT NULL,
      PRIMARY KEY (id, ep, page)
    );
  """);
  if (!_columns(db, 'image_favorites').contains('updatedAt')) {
    db.execute('alter table image_favorites add column updatedAt int;');
  }
  db.execute("""
    create table if not exists image_tombstone (
      id TEXT,
      ep INTEGER,
      page INTEGER,
      deleted_at INTEGER,
      primary key (id, ep, page)
    );
  """);
}

void _mergeHistoryTable(
    Database local, _AttachedRemote remote, SyncStats stats) {
  if (!remote.hasTable('history')) {
    return;
  }
  final remoteHasMaxPage = remote.columns('history').contains('max_page');
  final localRows = <String, Map<String, dynamic>>{};
  for (final row in local.select('select * from history;')) {
    final data = _rowMap(row);
    final target = _str(data['target']);
    if (target.isNotEmpty) {
      localRows[target] = data;
    }
  }
  for (final row in remote.rows('history')) {
    final data = _rowMap(row);
    final target = _str(data['target']);
    if (target.isEmpty) {
      continue;
    }
    final localRow = localRows[target];
    final remoteTime = _int(data['time']);
    if (localRow == null) {
      local.execute(
        'insert into history (target, title, subtitle, cover, time, type, ep, page, readEpisode, max_page) '
        'values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          target,
          _str(data['title']),
          _str(data['subtitle']),
          _str(data['cover']),
          remoteTime,
          _int(data['type']),
          _int(data['ep']),
          _int(data['page']),
          _str(data['readEpisode']),
          remoteHasMaxPage ? data['max_page'] : null,
        ],
      );
      stats.inserted++;
      continue;
    }
    final localTime = _int(localRow['time']);
    if (remoteTime > localTime) {
      final episodes =
          _unionEpisodes(_str(localRow['readEpisode']), _str(data['readEpisode']));
      local.execute(
        'update history set title = ?, subtitle = ?, cover = ?, time = ?, type = ?, '
        'ep = ?, page = ?, readEpisode = ?, max_page = ? where target = ?;',
        [
          _str(data['title']),
          _str(data['subtitle']),
          _str(data['cover']),
          remoteTime,
          _int(data['type']),
          _int(data['ep']),
          _int(data['page']),
          episodes,
          remoteHasMaxPage ? data['max_page'] : localRow['max_page'],
          target,
        ],
      );
      stats.updated++;
    } else {
      stats.skipped++;
    }
  }
}

String _unionEpisodes(String a, String b) {
  final set = <String>{};
  for (final value in '$a,$b'.split(',')) {
    final ep = int.tryParse(value.trim());
    if (ep != null) {
      set.add(ep.toString());
    }
  }
  final list = set.map(int.parse).toList()..sort();
  return list.join(',');
}

String _imageKey(dynamic id, int ep, int page) => '$id\u0000$ep\u0000$page';

void _mergeImageFavorites(
    Database local, _AttachedRemote remote, SyncStats stats, int nowMs) {
  if (!remote.hasTable('image_favorites')) {
    return;
  }
  final remoteHasUpdatedAt = remote.columns('image_favorites').contains('updatedAt');

  final localRows = <String, Map<String, dynamic>>{};
  for (final row in local.select('select * from image_favorites;')) {
    final data = _rowMap(row);
    localRows[_imageKey(data['id'], _int(data['ep']), _int(data['page']))] =
        data;
  }
  final remoteRows = <String, Map<String, dynamic>>{};
  for (final row in remote.rows('image_favorites')) {
    final data = _rowMap(row);
    remoteRows[_imageKey(data['id'], _int(data['ep']), _int(data['page']))] =
        data;
  }

  // 删除墓碑并集
  final tombstones = <String, int>{};
  for (final row in local.select('select * from image_tombstone;')) {
    final key = _imageKey(row['id'], _int(row['ep']), _int(row['page']));
    tombstones[key] = _int(row['deleted_at']);
  }
  if (remote.hasTable('image_tombstone')) {
    for (final row in remote.rows('image_tombstone')) {
      final key = _imageKey(row['id'], _int(row['ep']), _int(row['page']));
      final at = _int(row['deleted_at']);
      if (at > (tombstones[key] ?? 0)) {
        tombstones[key] = at;
        local.execute(
          'insert or replace into image_tombstone (id, ep, page, deleted_at) values (?, ?, ?, ?);',
          [row['id'], _int(row['ep']), _int(row['page']), at],
        );
      }
    }
  }

  final mergedKeys = <String>{...localRows.keys, ...remoteRows.keys};
  for (final key in mergedKeys) {
    final localRow = localRows[key];
    final remoteRow = remoteRows[key];
    final localUpdatedAt = _int(localRow?['updatedAt']);
    final remoteUpdatedAt =
        remoteHasUpdatedAt ? _int(remoteRow?['updatedAt']) : 0;
    final deletedAt = tombstones[key];
    if (deletedAt != null &&
        deletedAt >=
            (localUpdatedAt > remoteUpdatedAt
                ? localUpdatedAt
                : remoteUpdatedAt)) {
      if (localRow != null) {
        local.execute(
          'delete from image_favorites where id = ? and ep = ? and page = ?;',
          [localRow['id'], _int(localRow['ep']), _int(localRow['page'])],
        );
        stats.deleted++;
      }
      continue;
    }
    if (localRow == null && remoteRow != null) {
      _insertImage(local, remoteRow, remoteUpdatedAt);
      stats.inserted++;
    } else if (localRow != null &&
        remoteRow != null &&
        remoteUpdatedAt > localUpdatedAt) {
      _updateImage(local, remoteRow, remoteUpdatedAt);
      stats.updated++;
    } else {
      stats.skipped++;
    }
  }

  _purgeImageTombstones(local, nowMs);
}

void _insertImage(Database db, Map<String, dynamic> row, int updatedAt) {
  db.execute(
    'insert or replace into image_favorites (id, title, cover, ep, page, other, updatedAt) '
    'values (?, ?, ?, ?, ?, ?, ?);',
    [
      row['id'],
      _str(row['title']),
      _str(row['cover']),
      _int(row['ep']),
      _int(row['page']),
      _str(row['other']),
      updatedAt,
    ],
  );
}

void _updateImage(Database db, Map<String, dynamic> row, int updatedAt) {
  db.execute(
    'update image_favorites set title = ?, cover = ?, other = ?, updatedAt = ? '
    'where id = ? and ep = ? and page = ?;',
    [
      _str(row['title']),
      _str(row['cover']),
      _str(row['other']),
      updatedAt,
      row['id'],
      _int(row['ep']),
      _int(row['page']),
    ],
  );
}

void _purgeImageTombstones(Database db, int nowMs) {
  final before = nowMs - syncTombstoneRetention.inMilliseconds;
  db.execute('delete from image_tombstone where deleted_at < ?;', [before]);
}

// ---------------------------------------------------------------------------
// local_favorite.db: 各收藏夹表 + 删除墓碑
// ---------------------------------------------------------------------------

const Set<String> _systemFavoriteTables = {
  'folder_sync',
  'folder_order',
  'sync_tombstone',
};

const String _folderTableSql = '''
  create table if not exists "__folder__"(
    target text,
    name TEXT,
    author TEXT,
    type int,
    tags TEXT,
    cover_path TEXT,
    time TEXT,
    display_order int,
    primary key (target, type)
  );
''';

/// 合并本地收藏库 (各收藏夹子表 + folder_order + folder_sync + 删除墓碑)。
///
/// [local] 是调用方**已经打开**的 local_favorite.db 连接, 本函数只在它上面
/// ATTACH 远端库并写本地库, 不关闭、不重开连接。[remotePath] 是快照解压副本。
SyncStats mergeLocalFavoritesDatabase({
  required Database local,
  required String remotePath,
  required int nowMs,
  SyncMergeLog? log,
}) {
  final stats = SyncStats();
  final startedAt = DateTime.now();
  int elapsedMs() => DateTime.now().difference(startedAt).inMilliseconds;
  if (!_attachRemote(local, remotePath)) {
    return stats;
  }
  log?.call('ATTACH 远端 local_favorite.db', elapsedMs());
  final remote = _AttachedRemote(local);
  try {
    local.execute('begin immediate;');
    try {
      local.execute("""
        create table if not exists sync_tombstone (
          target TEXT,
          type INTEGER,
          folder TEXT,
          deleted_at INTEGER,
          primary key (target, type, folder)
        );
      """);
      final tombstones = _mergeFavoriteTombstones(local, remote);
      _mergeFolderOrder(local, remote);
      final folders = <String>{
        ..._favoriteFolders(local),
        ...remote.tableNames().where((name) => !_systemFavoriteTables.contains(name)),
      };
      for (final folder in folders) {
        if (!_tableExists(local, folder)) {
          local.execute(_folderTableSql.replaceFirst('__folder__', folder));
        }
        _mergeFavoriteFolder(local, remote, folder, tombstones, stats);
      }
      _mergeFolderSync(local, remote);
      _purgeFavoriteTombstones(local, nowMs);
      local.execute('commit;');
      log?.call('合并事务已提交', elapsedMs());
    } catch (_) {
      _rollback(local);
      rethrow;
    }
  } finally {
    _detachRemote(local);
    log?.call('DETACH 远端 local_favorite.db', elapsedMs());
  }
  return stats;
}

List<String> _favoriteFolders(Database db) {
  final names = <String>[];
  try {
    final tables = db.select("SELECT name FROM sqlite_master WHERE type='table';");
    for (final row in tables) {
      final name = row['name'].toString();
      if (!_systemFavoriteTables.contains(name)) {
        names.add(name);
      }
    }
  } catch (_) {
    names.clear();
  }
  return names;
}

Map<String, int> _mergeFavoriteTombstones(
    Database local, _AttachedRemote remote) {
  final tombstones = <String, int>{};
  for (final row in local.select('select * from sync_tombstone;')) {
    tombstones[_favoriteTombstoneKey(row)] = _int(row['deleted_at']);
  }
  if (!remote.hasTable('sync_tombstone')) {
    return tombstones;
  }
  for (final row in remote.rows('sync_tombstone')) {
    final key = _favoriteTombstoneKey(row);
    final at = _int(row['deleted_at']);
    if (at > (tombstones[key] ?? 0)) {
      tombstones[key] = at;
      local.execute(
        'insert or replace into sync_tombstone (target, type, folder, deleted_at) '
        'values (?, ?, ?, ?);',
        [_str(row['target']), _int(row['type']), _str(row['folder']), at],
      );
    }
  }
  return tombstones;
}

String _favoriteTombstoneKey(Row row) =>
    '${_str(row['folder'])}\u0000${_str(row['target'])}\u0000${_int(row['type'])}';

String _favoriteKey(String folder, String target, int type) =>
    '$folder\u0000$target\u0000$type';

void _mergeFolderOrder(Database local, _AttachedRemote remote) {
  if (!remote.hasTable('folder_order')) {
    return;
  }
  final localOrder = <String, int>{};
  if (_tableExists(local, 'folder_order')) {
    for (final row in local.select('select * from folder_order;')) {
      localOrder[_str(row['folder_name'])] = _int(row['order_value']);
    }
  } else {
    local.execute(
        'create table folder_order (folder_name text primary key, order_value int);');
  }
  for (final row in remote.rows('folder_order')) {
    final folder = _str(row['folder_name']);
    if (folder.isEmpty) {
      continue;
    }
    final value = _int(row['order_value']);
    if (!localOrder.containsKey(folder) || value > localOrder[folder]!) {
      local.execute(
        'insert or replace into folder_order (folder_name, order_value) values (?, ?);',
        [folder, value],
      );
    }
  }
}

void _mergeFavoriteFolder(Database local, _AttachedRemote remote,
    String folder, Map<String, int> tombstones, SyncStats stats) {
  if (!remote.hasTable(folder)) {
    return;
  }
  final localRows = <String, Map<String, dynamic>>{};
  for (final row in local.select('select * from "$folder";')) {
    final data = _rowMap(row);
    localRows[_favoriteKey(folder, _str(data['target']), _int(data['type']))] =
        data;
  }
  final remoteRows = <String, Map<String, dynamic>>{};
  for (final row in remote.rows(folder)) {
    final data = _rowMap(row);
    remoteRows[_favoriteKey(folder, _str(data['target']), _int(data['type']))] =
        data;
  }
  for (final key in <String>{...localRows.keys, ...remoteRows.keys}) {
    final localRow = localRows[key];
    final remoteRow = remoteRows[key];
    final localTime = _str(localRow?['time']);
    final remoteTime = _str(remoteRow?['time']);
    final newestTime = _newerIsoTime(localTime, remoteTime);
    final deletedAt = tombstones[key];
    if (deletedAt != null && deletedAt >= _isoTimeToMs(newestTime)) {
      if (localRow != null) {
        local.execute(
          'delete from "$folder" where target = ? and type = ?;',
          [_str(localRow['target']), _int(localRow['type'])],
        );
        stats.deleted++;
      }
      continue;
    }
    if (localRow == null && remoteRow != null) {
      _insertFavorite(local, folder, remoteRow);
      stats.inserted++;
    } else if (localRow != null && remoteRow != null) {
      if (remoteTime.isNotEmpty && remoteTime.compareTo(localTime) > 0) {
        _updateFavorite(local, folder, remoteRow);
        stats.updated++;
      } else {
        stats.skipped++;
      }
    }
  }
}

String _newerIsoTime(String a, String b) {
  if (a.isEmpty) {
    return b;
  }
  if (b.isEmpty) {
    return a;
  }
  return a.compareTo(b) >= 0 ? a : b;
}

/// 收藏表的 time 是 "yyyy-MM-dd HH:mm:ss" 的本地时间字符串, 这里换成毫秒近似值
/// (只用于和墓碑时间比大小; 解析失败按 0 处理, 即视为最早)
int _isoTimeToMs(String value) {
  if (value.isEmpty) {
    return 0;
  }
  final normalized = value.replaceFirst(' ', 'T');
  final parsed = DateTime.tryParse(normalized);
  return parsed?.millisecondsSinceEpoch ?? 0;
}

void _insertFavorite(Database db, String folder, Map<String, dynamic> row) {
  db.execute(
    'insert or replace into "$folder" '
    '(target, name, author, type, tags, cover_path, time, display_order) '
    'values (?, ?, ?, ?, ?, ?, ?, ?);',
    [
      _str(row['target']),
      _str(row['name']),
      _str(row['author']),
      _int(row['type']),
      _str(row['tags']),
      _str(row['cover_path']),
      _str(row['time']),
      _int(row['display_order']),
    ],
  );
}

void _updateFavorite(Database db, String folder, Map<String, dynamic> row) {
  db.execute(
    'update "$folder" set name = ?, author = ?, tags = ?, cover_path = ?, '
    'time = ?, display_order = ? where target = ? and type = ?;',
    [
      _str(row['name']),
      _str(row['author']),
      _str(row['tags']),
      _str(row['cover_path']),
      _str(row['time']),
      _int(row['display_order']),
      _str(row['target']),
      _int(row['type']),
    ],
  );
}

void _mergeFolderSync(Database local, _AttachedRemote remote) {
  if (!remote.hasTable('folder_sync')) {
    return;
  }
  if (!_tableExists(local, 'folder_sync')) {
    local.execute("""
      create table folder_sync (
        folder_name text primary key,
        time TEXT,
        key TEXT,
        sync_data TEXT
      );
    """);
  }
  final localFolders = local
      .select('select folder_name from folder_sync;')
      .map((row) => _str(row['folder_name']))
      .toSet();
  for (final row in remote.rows('folder_sync')) {
    final folder = _str(row['folder_name']);
    if (folder.isEmpty || localFolders.contains(folder)) {
      continue;
    }
    local.execute(
      'insert or replace into folder_sync (folder_name, time, key, sync_data) '
      'values (?, ?, ?, ?);',
      [folder, _str(row['time']), _str(row['key']), _str(row['sync_data'])],
    );
  }
}

void _purgeFavoriteTombstones(Database db, int nowMs) {
  final before = nowMs - syncTombstoneRetention.inMilliseconds;
  db.execute('delete from sync_tombstone where deleted_at < ?;', [before]);
}

// ---------------------------------------------------------------------------
// read_positions.json
// ---------------------------------------------------------------------------

class ReadPositionEntry {
  final int page;

  /// 毫秒时间戳; 旧版本文件没有这个字段, 记为 0
  final int updatedAt;

  const ReadPositionEntry(this.page, this.updatedAt);

  Map<String, dynamic> toJson() => {'page': page, 'updatedAt': updatedAt};
}

/// 作品 -> (话号 -> 页码+修改时间)
typedef ReadPositions = Map<String, Map<int, ReadPositionEntry>>;

/// 解析 read_positions.json, 兼容旧格式 ${target: ${ep: page}}。
ReadPositions parseReadPositions(String? raw) {
  final result = <String, Map<int, ReadPositionEntry>>{};
  if (raw == null || raw.trim().isEmpty) {
    return result;
  }
  dynamic json;
  try {
    json = jsonDecode(raw);
  } catch (_) {
    return result;
  }
  if (json is! Map) {
    return result;
  }
  final bool isVersion2 = json['version'] == 2 && json['targets'] is Map;
  final targets = isVersion2 ? json['targets'] as Map : json;
  for (final entry in targets.entries) {
    final target = entry.key.toString();
    final value = entry.value;
    if (value is! Map) {
      continue;
    }
    final eps = <int, ReadPositionEntry>{};
    for (final epEntry in value.entries) {
      final ep = int.tryParse(epEntry.key.toString());
      if (ep == null) {
        continue;
      }
      final rawValue = epEntry.value;
      if (rawValue is num) {
        if (rawValue > 0) {
          eps[ep] = ReadPositionEntry(rawValue.toInt(), 0);
        }
      } else if (rawValue is Map) {
        final page = _int(rawValue['page']);
        if (page > 0) {
          eps[ep] = ReadPositionEntry(page, _int(rawValue['updatedAt']));
        }
      }
    }
    if (eps.isNotEmpty) {
      result[target] = eps;
    }
  }
  return result;
}

String encodeReadPositions(ReadPositions positions) =>
    const JsonEncoder.withIndent('  ').convert({
      'version': 2,
      'targets': {
        for (final target in positions.entries)
          target.key: {
            for (final ep in target.value.entries)
              ep.key.toString(): ep.value.toJson(),
          },
      },
    });

class ReadPositionsMergeResult {
  final ReadPositions merged;

  final SyncStats stats;

  ReadPositionsMergeResult(this.merged, this.stats);
}

/// 按 target+ep 合并: updatedAt 更晚者胜; 两边都没有时间戳(旧数据)时保留本地。
ReadPositionsMergeResult mergeReadPositions(
    ReadPositions local, ReadPositions remote) {
  final stats = SyncStats();
  final merged = <String, Map<int, ReadPositionEntry>>{};
  for (final entry in local.entries) {
    merged[entry.key] = Map<int, ReadPositionEntry>.from(entry.value);
  }
  for (final remoteTarget in remote.entries) {
    final localEps = merged[remoteTarget.key];
    if (localEps == null) {
      merged[remoteTarget.key] = Map<int, ReadPositionEntry>.from(remoteTarget.value);
      stats.inserted += remoteTarget.value.length;
      continue;
    }
    for (final remoteEp in remoteTarget.value.entries) {
      final localEntry = localEps[remoteEp.key];
      if (localEntry == null) {
        localEps[remoteEp.key] = remoteEp.value;
        stats.inserted++;
      } else if (remoteEp.value.updatedAt > localEntry.updatedAt) {
        localEps[remoteEp.key] = remoteEp.value;
        stats.updated++;
      } else {
        stats.skipped++;
      }
    }
  }
  return ReadPositionsMergeResult(merged, stats);
}

/// 合并后按 ReadPositionStore 的上限裁剪: 只留 updatedAt 最新的目标/话。
void trimReadPositions(
  ReadPositions positions, {
  required int maxTargets,
  required int maxEps,
}) {
  for (final target in positions.keys.toList()) {
    final eps = positions[target]!;
    if (eps.length > maxEps) {
      final keys = eps.keys.toList()
        ..sort((a, b) => eps[b]!.updatedAt.compareTo(eps[a]!.updatedAt));
      for (final key in keys.skip(maxEps)) {
        eps.remove(key);
      }
    }
    if (eps.isEmpty) {
      positions.remove(target);
    }
  }
  if (positions.length > maxTargets) {
    int newestUpdatedAt(String target) {
      var newest = 0;
      for (final entry in positions[target]!.values) {
        if (entry.updatedAt > newest) {
          newest = entry.updatedAt;
        }
      }
      return newest;
    }

    final keys = positions.keys.toList()
      ..sort((a, b) => newestUpdatedAt(b).compareTo(newestUpdatedAt(a)));
    for (final key in keys.skip(maxTargets)) {
      positions.remove(key);
    }
  }
}

// ---------------------------------------------------------------------------
// 设置与 appdata
// ---------------------------------------------------------------------------

class SettingsMergeResult {
  final List<String> settings;

  final Map<int, int> meta;

  /// 真正被远端覆盖的设置项数量
  final int updated;

  SettingsMergeResult(this.settings, this.meta, this.updated);
}

/// 按设置下标逐项合并: 远端 modifiedAt 更晚才覆盖本地。
///
/// [excluded] 里的下标(设备相关项)永远保留本地值。
SettingsMergeResult mergeSettings({
  required List<String> local,
  required Map<int, int> localMeta,
  required List<String> remote,
  required Map<int, int> remoteMeta,
  Set<int> excluded = const {},
}) {
  final settings = List<String>.from(local);
  final meta = Map<int, int>.from(localMeta);
  var updated = 0;
  final length = local.length < remote.length ? local.length : remote.length;
  for (var index = 0; index < length; index++) {
    if (excluded.contains(index)) {
      continue;
    }
    final localTime = localMeta[index] ?? 0;
    final remoteTime = remoteMeta[index] ?? 0;
    if (remoteTime > localTime) {
      if (settings[index] != remote[index]) {
        settings[index] = remote[index];
        updated++;
      }
      meta[index] = remoteTime;
    } else if (remoteTime > (meta[index] ?? 0)) {
      meta[index] = remoteTime;
    }
  }
  return SettingsMergeResult(settings, meta, updated);
}

List<String> _stringList(dynamic value) {
  if (value is List) {
    return value.map((e) => e.toString()).toList();
  }
  return <String>[];
}

List<String> _unionStringList(List<String> a, List<String> b) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in [...a, ...b]) {
    if (seen.add(value)) {
      result.add(value);
    }
  }
  return result;
}

/// 合并 appdata JSON: 设置走 [mergeSettings] 的结果, 屏蔽词/收藏标签取并集,
/// firstUse 保留本地。
Map<String, dynamic> mergeAppdataJson({
  required Map<String, dynamic> local,
  required Map<String, dynamic> remote,
  required SettingsMergeResult settings,
}) {
  final merged = Map<String, dynamic>.from(local);
  // 输出统一成 List<String>: base.dart 的 readDataFromJson 会直接拿它和本地
  // List<String> 做集合运算, 留 List<dynamic> 会在真机上抛类型错误
  merged['settings'] = List<String>.from(settings.settings);
  merged['firstUse'] = _stringList(local['firstUse'] ?? remote['firstUse']);
  merged['blockingKeywords'] = _unionStringList(
    _stringList(local['blockingKeywords']),
    _stringList(remote['blockingKeywords']),
  );
  merged['favoriteTags'] = _unionStringList(
    _stringList(local['favoriteTags']),
    _stringList(remote['favoriteTags']),
  );
  return merged;
}
