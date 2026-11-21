/// WebDAV 同步合并逻辑冒烟测试 (纯 Dart, 不需要 Flutter):
///
///   dart run tool/sync_merge_smoke.dart
///
/// 用临时目录造两个真实的 sqlite 库 + 两份 read_positions.json + 两份设置 JSON,
/// 覆盖: 远端新增 / 同 target 取新 / 删除墓碑 / 设置按项取新 / 设备相关项不参与 /
/// cookies 不参与 / 旧格式快照与旧格式阅读位置兼容。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:pica_comic/foundation/sync/sync_merge.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

int _failed = 0;

int _passed = 0;

void _check(String name, bool ok, [String extra = '']) {
  if (ok) {
    _passed++;
    print('  PASS  $name');
  } else {
    _failed++;
    print('  FAIL  $name${extra.isEmpty ? '' : ' -> $extra'}');
  }
}

void _checkEquals(String name, Object? actual, Object? expected) =>
    _check(name, actual == expected, 'actual=$actual expected=$expected');

void _openSqlite(DynamicLibrary lib) {
  open.overrideForAll(() => lib);
}

void main() {
  if (Platform.isLinux) {
    // 宿主只有 libsqlite3.so.0, 没有 unversioned 的 libsqlite3.so
    try {
      _openSqlite(DynamicLibrary.open('libsqlite3.so.0'));
    } catch (e) {
      print('warn: 无法加载 libsqlite3.so.0: $e');
    }
  }
  final dir = Directory.systemTemp.createTempSync('pica_sync_smoke_');
  try {
    _testHistoryAndImages('${dir.path}/history');
    _testLocalFavorites('${dir.path}/favorites');
    _testReadPositions();
    _testSettings();
    _testProtocol();
    _testIdempotent('${dir.path}/history', '${dir.path}/favorites');
  } finally {
    dir.deleteSync(recursive: true);
  }
  print('');
  print('通过 $_passed, 失败 $_failed');
  if (_failed > 0) {
    exitCode = 1;
    throw StateError('sync merge smoke test failed');
  }
}

// ---------------------------------------------------------------------------
// history.db / image_favorites
// ---------------------------------------------------------------------------

const String _historyDdl = '''
  create table history (
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
''';

const String _imageDdl = '''
  create table image_favorites (
    id TEXT,
    title TEXT NOT NULL,
    cover TEXT NOT NULL,
    ep INTEGER NOT NULL,
    page INTEGER NOT NULL,
    other TEXT NOT NULL,
    PRIMARY KEY (id, ep, page)
  );
''';

void _testHistoryAndImages(String base) {
  print('[history.db]');
  final localPath = '${base}_local.db';
  final remotePath = '${base}_remote.db';
  final local = sqlite3.open(localPath);
  local.execute(_historyDdl);
  local.execute(_imageDdl);
  local.execute('insert into history values (?,?,?,?,?,?,?,?,?,?)',
      ['targetA', 'A(old)', '', 'a.jpg', 100, 2, 3, 5, '1,2', 20]);
  local.execute('insert into history values (?,?,?,?,?,?,?,?,?,?)',
      ['targetB', 'B(local newer)', '', 'b.jpg', 300, 2, 8, 9, '1,2', 30]);
  local.execute('insert into history values (?,?,?,?,?,?,?,?,?,?)',
      ['targetD', 'D(local only)', '', 'd.jpg', 50, 2, 1, 1, '1', 10]);
  local.execute(
      'insert into image_favorites values (?,?,?,?,?,?)',
      ['img1', 'img1-title', 'img1-cover', 1, 1, '{}']);
  local.execute(
      'insert into image_favorites values (?,?,?,?,?,?)',
      ['img2', 'img2-title', 'img2-cover', 1, 1, '{}']);
  local.execute(
      'insert into image_favorites values (?,?,?,?,?,?)',
      ['img3', 'img3-title', 'img3-cover', 1, 1, '{}']);
  // 本机已经有 updatedAt 列
  local.execute('alter table image_favorites add column updatedAt int;');
  local.execute("update image_favorites set updatedAt = 100 where id = 'img1'");
  local.execute("update image_favorites set updatedAt = 500 where id = 'img2'");
  local.execute("update image_favorites set updatedAt = 100 where id = 'img3'");
  local.execute('''
    create table image_tombstone (id TEXT, ep INTEGER, page INTEGER, deleted_at INTEGER,
      primary key (id, ep, page));
  ''');
  local.dispose();

  final remote = sqlite3.open(remotePath);
  remote.execute(_historyDdl);
  remote.execute(_imageDdl);
  remote.execute('insert into history values (?,?,?,?,?,?,?,?,?,?)',
      ['targetA', 'A(new)', '', 'a.jpg', 200, 2, 4, 6, '2,3', 40]);
  remote.execute('insert into history values (?,?,?,?,?,?,?,?,?,?)',
      ['targetB', 'B(remote older)', '', 'b.jpg', 100, 2, 2, 2, '1', 10]);
  remote.execute('insert into history values (?,?,?,?,?,?,?,?,?,?)',
      ['targetC', 'C(remote only)', '', 'c.jpg', 400, 2, 5, 7, '1', 50]);
  remote.execute(
      'insert into image_favorites values (?,?,?,?,?,?)',
      ['img1', 'img1-title-new', 'img1-cover', 1, 1, '{}']);
  remote.execute(
      'insert into image_favorites values (?,?,?,?,?,?)',
      ['img4', 'img4-title', 'img4-cover', 1, 1, '{}']);
  remote.execute(
      'insert into image_favorites values (?,?,?,?,?,?)',
      ['img3', 'img3-title', 'img3-cover', 1, 1, '{}']);
  remote.execute('alter table image_favorites add column updatedAt int;');
  remote.execute("update image_favorites set updatedAt = 200 where id = 'img1'");
  remote.execute("update image_favorites set updatedAt = 250 where id = 'img4'");
  remote.execute("update image_favorites set updatedAt = 50 where id = 'img3'");
  remote.execute('''
    create table image_tombstone (id TEXT, ep INTEGER, page INTEGER, deleted_at INTEGER,
      primary key (id, ep, page));
  ''');
  // img2: 远端刚删掉它(本地 500 的修改更早); img3: 同样被删。
  // 墓碑时间用"现在", 否则会被保留期清理掉
  const now = 1760000000000;
  remote.execute(
      "insert into image_tombstone values ('img2', 1, 1, ?)", [now - 86400000]);
  remote.execute(
      "insert into image_tombstone values ('img3', 1, 1, ?)", [now - 86400000]);
  remote.dispose();
  final stats = mergeHistoryDatabase(
      localPath: localPath, remotePath: remotePath, nowMs: now);
  // history 插入 C + image 插入 img4 = 2; history 更新 A + image 更新 img1 = 2
  _checkEquals('history 远端新增插入 1 + image 插入 1', stats.inserted, 2);
  _checkEquals('history 同 target 取新 1 + image 更新 1', stats.updated, 2);
  _checkEquals('history 本地更新时跳过 1', stats.skipped, 1);
  _checkEquals('image 墓碑删除 2', stats.deleted, 2);
  final db = sqlite3.open(localPath);
  final a = db.select("select * from history where target = 'targetA'").first;
  _checkEquals('A 取远端标题', a['title'], 'A(new)');
  _checkEquals('A 取远端页码', a['page'], 6);
  _checkEquals('A 的 readEpisode 取并集', a['readEpisode'], '1,2,3');
  final b = db.select("select * from history where target = 'targetB'").first;
  _checkEquals('B 保留本地较新标题', b['title'], 'B(local newer)');
  _checkEquals('B 本地页码不变', b['page'], 9);
  _check('C 远端新增已插入',
      db.select("select count(*) c from history where target = 'targetC'").first['c'] == 1);
  _check('D 本地独有保留',
      db.select("select count(*) c from history where target = 'targetD'").first['c'] == 1);
  _checkEquals('image img1 更新为远端', db.select(
          "select title from image_favorites where id = 'img1'").first['title'],
      'img1-title-new');
  _check('image img4 插入', db.select(
          "select count(*) c from image_favorites where id = 'img4'").first['c'] == 1);
  _check('image img2 被远端墓碑删除', db.select(
          "select count(*) c from image_favorites where id = 'img2'").first['c'] == 0);
  _check('image img3 被远端墓碑删除', db.select(
          "select count(*) c from image_favorites where id = 'img3'").first['c'] == 0);
  _check('删除墓碑已同步到本地', db.select(
          "select count(*) c from image_tombstone").first['c'] == 2);
  db.dispose();
}

// ---------------------------------------------------------------------------
// local_favorite.db
// ---------------------------------------------------------------------------

const String _folderDdl = '''
  create table "__folder__"(
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

void _createFolder(Database db, String folder) {
  db.execute(_folderDdl.replaceFirst('__folder__', folder));
}

void _addFavorite(Database db, String folder, String target, String time,
    {int order = 0, int type = 2}) {
  db.execute(
    'insert or replace into "$folder" '
    '(target, name, author, type, tags, cover_path, time, display_order) '
    'values (?, ?, ?, ?, ?, ?, ?, ?);',
    [target, 'name-$target', 'author', type, 'tag1,tag2', 'cover.jpg', time, order],
  );
}

void _testLocalFavorites(String base) {
  print('[local_favorite.db]');
  final localPath = '${base}_local.db';
  final remotePath = '${base}_remote.db';
  final local = sqlite3.open(localPath);
  _createFolder(local, '默认');
  _createFolder(local, '稍后再看');
  _createFolderOrder(local);
  local.execute('insert or replace into folder_order values (?, ?)', ['默认', 0]);
  local.execute('insert or replace into folder_order values (?, ?)', ['稍后再看', 1]);
  _createFolderSync(local);
  _createTombstone(local);
  _addFavorite(local, '默认', 't1', '2026-01-01 00:00:00');
  _addFavorite(local, '默认', 't2', '2026-02-01 00:00:00');
  _addFavorite(local, '默认', 't3', '2026-01-05 00:00:00');
  _addFavorite(local, '稍后再看', 't7', '2026-01-02 00:00:00');
  local.dispose();

  final remote = sqlite3.open(remotePath);
  _createFolder(remote, '默认');
  _createFolder(remote, '网络收藏');
  _createFolderOrder(remote);
  remote.execute('insert or replace into folder_order values (?, ?)', ['默认', 0]);
  remote.execute('insert or replace into folder_order values (?, ?)', ['网络收藏', 2]);
  _createFolderSync(remote);
  _createTombstone(remote);
  _addFavorite(remote, '默认', 't1', '2026-03-01 00:00:00');
  _addFavorite(remote, '默认', 't2', '2025-12-01 00:00:00');
  _addFavorite(remote, '默认', 't4', '2026-01-01 00:00:00');
  _addFavorite(remote, '默认', 't5', '2026-01-01 00:00:00');
  _addFavorite(remote, '网络收藏', 't6', '2026-01-01 00:00:00');
  // 远端在 2026-01-10 删了 t3, t5(后加的)也被删
  remote.execute(
      "insert into sync_tombstone values ('t3', 2, '默认', ?)",
      [DateTime(2026, 1, 10).millisecondsSinceEpoch]);
  remote.execute(
      "insert into sync_tombstone values ('t5', 2, '默认', ?)",
      [DateTime(2026, 2, 10).millisecondsSinceEpoch]);
  remote.dispose();

  final stats = mergeLocalFavoritesDatabase(
      localPath: localPath,
      remotePath: remotePath,
      nowMs: DateTime(2026, 3, 2).millisecondsSinceEpoch);
  _checkEquals('收藏 远端新增插入 2 (t4 + 新收藏夹 t6)', stats.inserted, 2);
  _checkEquals('收藏 同 target 取新 1 (t1)', stats.updated, 1);
  _checkEquals('收藏 本地更新跳过 1 (t2)', stats.skipped, 1);
  _checkEquals('收藏 删除墓碑生效 1 (t3)', stats.deleted, 1);

  final db = sqlite3.open(localPath);
  final t1 = db.select("select * from \"默认\" where target = 't1'").first;
  _checkEquals('t1 取远端较新时间', t1['time'], '2026-03-01 00:00:00');
  final t2 = db.select("select * from \"默认\" where target = 't2'").first;
  _checkEquals('t2 保留本地时间', t2['time'], '2026-02-01 00:00:00');
  _check('t4 已插入', db.select(
          "select count(*) c from \"默认\" where target = 't4'").first['c'] == 1);
  _check('t5 被墓碑挡住没有插入', db.select(
          "select count(*) c from \"默认\" where target = 't5'").first['c'] == 0);
  _check('t3 被墓碑删除', db.select(
          "select count(*) c from \"默认\" where target = 't3'").first['c'] == 0);
  _check('本地独有收藏夹保留', db.select(
          "select count(*) c from \"稍后再看\"").first['c'] == 1);
  _check('远端新收藏夹已建表并插入', db.select(
          "select count(*) c from \"网络收藏\" where target = 't6'").first['c'] == 1);
  _check('删除墓碑已同步到本地', db.select(
          "select count(*) c from sync_tombstone").first['c'] == 2);
  _check('新收藏夹顺序已合并', db.select(
          "select order_value from folder_order where folder_name = '网络收藏'")
      .first['order_value'] == 2);
  db.dispose();
}

void _createFolderSync(Database db) {
  db.execute('''
    create table folder_sync (
      folder_name text primary key,
      time TEXT,
      key TEXT,
      sync_data TEXT
    );
  ''');
}

void _createFolderOrder(Database db) {
  db.execute('''
    create table folder_order (
      folder_name text primary key,
      order_value int
    );
  ''');
}

void _createTombstone(Database db) {
  db.execute('''
    create table sync_tombstone (
      target TEXT,
      type INTEGER,
      folder TEXT,
      deleted_at INTEGER,
      primary key (target, type, folder)
    );
  ''');
}

// ---------------------------------------------------------------------------
// read_positions.json
// ---------------------------------------------------------------------------

void _testReadPositions() {
  print('[read_positions.json]');
  final local = parseReadPositions(jsonEncode({
    'A': {'1': 5, '2': 3},
  }));
  _checkEquals('旧格式解析 A/1 页码', local['A']?[1]?.page, 5);
  _checkEquals('旧格式解析 A/1 没有时间戳', local['A']?[1]?.updatedAt, 0);

  final remote = parseReadPositions(jsonEncode({
    'version': 2,
    'targets': {
      'A': {
        '1': {'page': 9, 'updatedAt': 200},
        '2': {'page': 7, 'updatedAt': 0},
      },
      'B': {
        '1': {'page': 4, 'updatedAt': 50},
      },
    },
  }));
  _checkEquals('v2 解析 A/1 页码', remote['A']?[1]?.page, 9);

  final result = mergeReadPositions(local, remote);
  _checkEquals('同一话取更新页码', result.merged['A']?[1]?.page, 9);
  _checkEquals('本地时间戳为 0 时保留本地页码', result.merged['A']?[2]?.page, 3);
  _checkEquals('远端新增 target 插入', result.merged['B']?[1]?.page, 4);
  _checkEquals('阅读位置 插入计数', result.stats.inserted, 1);
  _checkEquals('阅读位置 更新计数', result.stats.updated, 1);
  _checkEquals('阅读位置 跳过计数', result.stats.skipped, 1);

  final encoded = encodeReadPositions(result.merged);
  final reparsed = parseReadPositions(encoded);
  _checkEquals('编码后可回读', reparsed['B']?[1]?.page, 4);
  _check('编码格式带 version 2', encoded.contains('"version": 2'));

  final trimmed = parseReadPositions(jsonEncode({
    'version': 2,
    'targets': {
      'X': {'1': {'page': 1, 'updatedAt': 10}},
      'Y': {'1': {'page': 1, 'updatedAt': 20}},
    },
  }));
  trimReadPositions(trimmed, maxTargets: 1, maxEps: 10);
  _check('超上限时保留最新的作品', trimmed.containsKey('Y') && !trimmed.containsKey('X'));
}

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------

void _testSettings() {
  print('[settings]');
  final local = List<String>.generate(50, (i) => 'local-$i');
  final remote = List<String>.generate(50, (i) => 'remote-$i');
  final localMeta = <int, int>{1: 100, 2: 500};
  final remoteMeta = <int, int>{
    1: 200,
    2: 100,
    3: 200,
    8: 9999,
    13: 9999,
    22: 9999,
    38: 9999,
    45: 9999,
    46: 9999,
  };
  final result = mergeSettings(
    local: local,
    localMeta: localMeta,
    remote: remote,
    remoteMeta: remoteMeta,
    excluded: syncExcludedSettingIndices.toSet(),
  );
  _checkEquals('远端更晚的设置项被覆盖', result.settings[1], 'remote-1');
  _checkEquals('本地更晚的设置项保留', result.settings[2], 'local-2');
  _checkEquals('远端有新修改时间的新项被采用', result.settings[3], 'remote-3');
  _checkEquals('两边都没改过的项保留本地', result.settings[5], 'local-5');
  _checkEquals('覆盖计数为 2', result.updated, 2);
  for (final index in syncExcludedSettingIndices) {
    _checkEquals('设备相关项 $index 不参与同步', result.settings[index], 'local-$index');
  }
  _checkEquals('meta 记录远端修改时间', result.meta[3], 200);

  final mergedAppdata = mergeAppdataJson(
    local: {
      'settings': local,
      'firstUse': ['1', '1', '1', '1', '1'],
      'blockingKeywords': ['foo'],
      'favoriteTags': ['tagA'],
    },
    remote: {
      'settings': remote,
      'firstUse': ['0', '0', '0', '0', '0'],
      'blockingKeywords': ['foo', 'bar'],
      'favoriteTags': ['tagB'],
    },
    settings: result,
  );
  _checkEquals('设置合并结果写回 appdata',
      (mergedAppdata['settings'] as List)[1], 'remote-1');
  _checkEquals('屏蔽词取并集',
      (mergedAppdata['blockingKeywords'] as List).join(','), 'foo,bar');
  _checkEquals('收藏标签取并集',
      (mergedAppdata['favoriteTags'] as List).join(','), 'tagA,tagB');
  _checkEquals('firstUse 保留本地', (mergedAppdata['firstUse'] as List)[3], '1');
}

// ---------------------------------------------------------------------------
// 协议层: 快照清单 / 文件名 / settings_meta
// ---------------------------------------------------------------------------

void _testProtocol() {
  print('[protocol]');
  final files = syncSnapshotFileNames();
  _check('快照不含 cookies.db', !files.any((f) => f.contains('cookies')));
  _check('快照不含下载目录', !files.any((f) => f.contains('download')));
  _check('快照包含 history.db', files.contains('history.db'));
  _check('快照包含 local_favorite.db', files.contains('local_favorite.db'));
  _check('快照包含 read_positions.json', files.contains('read_positions.json'));
  _check('快照包含 settings_meta.json', files.contains('settings_meta.json'));
  _check('快照包含 appdata', files.contains('appdata'));

  _check('识别旧格式快照名', isLegacySnapshotName('1700000000.picadata'));
  _check('设备快照名不是旧格式',
      !isLegacySnapshotName('6f1c2b3a-0000-4000-8000-000000000000.picadata'));
  _checkEquals('旧格式版本号', legacySnapshotVersion('1700000123.picadata'), 1700000123);
  _checkEquals('设备文件名', deviceSnapshotName('dev1'), 'dev1.picadata');
  _checkEquals('从文件名取 deviceId', deviceIdFromSnapshotName('dev1.picadata'), 'dev1');
  _check('旧格式不算设备快照', deviceIdFromSnapshotName('1700000000.picadata') == null);
  _checkEquals('设备文件路径', syncDevicePath('dev1'), 'devices/dev1.picadata');

  const manifest = SyncManifest(
    version: syncProtocolVersion,
    deviceId: 'dev1',
    updatedAt: 123,
    files: {'history.db': 'abc'},
  );
  final parsed = SyncManifest.tryParse(manifest.encode());
  _checkEquals('manifest 回读 deviceId', parsed?.deviceId, 'dev1');
  _checkEquals('manifest 回读文件 hash', parsed?.files['history.db'], 'abc');

  final meta = decodeSettingsMeta(encodeSettingsMeta({1: 100, 45: 200}));
  _checkEquals('settings_meta 回读', meta[45], 200);

  final state = SyncState(deviceId: 'dev1')
    ..lastSyncAt = 456
    ..lastResult = 'ok'
    ..devices['dev2'] = SyncDeviceState(eTag: 'etag', size: 12)
    ..lastStats = SyncStats.of(1, 2, 3, 4)
    ..pulledDevices = ['dev2'];
  final state2 = SyncState.tryParse(state.encode());
  _checkEquals('sync_state 回读 deviceId', state2?.deviceId, 'dev1');
  _checkEquals('sync_state 回读 lastSyncAt', state2?.lastSyncAt, 456);
  _checkEquals('sync_state 回读设备 etag', state2?.devices['dev2']?.eTag, 'etag');
  _checkEquals('sync_state 回读合并计数', state2?.lastStats.deleted, 3);
}

// ---------------------------------------------------------------------------
// 重复合并应当幂等
// ---------------------------------------------------------------------------

void _testIdempotent(String historyBase, String favoritesBase) {
  print('[idempotent]');
  final historyStats = mergeHistoryDatabase(
    localPath: '${historyBase}_local.db',
    remotePath: '${historyBase}_remote.db',
    nowMs: 1760000000000,
  );
  _checkEquals('历史记录二次合并没有插入', historyStats.inserted, 0);
  _checkEquals('历史记录二次合并没有更新', historyStats.updated, 0);
  final favoritesStats = mergeLocalFavoritesDatabase(
    localPath: '${favoritesBase}_local.db',
    remotePath: '${favoritesBase}_remote.db',
    nowMs: DateTime(2026, 3, 2).millisecondsSinceEpoch,
  );
  _checkEquals('收藏二次合并没有插入', favoritesStats.inserted, 0);
  _checkEquals('收藏二次合并没有更新', favoritesStats.updated, 0);
  _checkEquals('收藏二次合并没有删除', favoritesStats.deleted, 0);
}
