/// WebDAV 同步协议里的纯 Dart 部分: 协议常量、快照文件清单、同步状态与清单文件。
///
/// 这里刻意不 import Flutter, 这样 [tool/sync_merge_smoke.dart] 可以直接
/// `dart run` 来跑合并逻辑。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 快照协议版本, 写进 manifest.json 和 state.json
const int syncProtocolVersion = 2;

/// 远端存放设备快照的目录名
const String syncDevicesDirName = 'devices';

/// 远端诊断文件: 只记录最近一次写入者, 不参与合并
const String syncStateRemoteFileName = 'state.json';

/// 快照内的清单文件: 每台设备自己的文件 hash 与写入时间
const String syncManifestFileName = 'manifest.json';

/// 设置项修改时间: {设置下标: 毫秒时间戳}
const String syncSettingsMetaFileName = 'settings_meta.json';

const String syncReadPositionsFileName = 'read_positions.json';

const String syncHistoryDbFileName = 'history.db';

const String syncLocalFavoritesDbFileName = 'local_favorite.db';

const String syncAppdataFileName = 'appdata';

const String syncComicSourceDirName = 'comic_source';

/// 设备快照文件名后缀, 完整名为 `<deviceId>.picadata`
const String syncSnapshotSuffix = '.picadata';

/// 设备相关项, 不参与同步: 代理(8)、生物识别(13)、下载目录(22)、
/// 高刷新率(38)、WebDAV 配置(45)、旧的数据版本号(46)
const List<int> syncExcludedSettingIndices = [8, 13, 22, 38, 45, 46];

/// 本地变更后延迟多久上传自己的快照
const Duration syncUploadDebounce = Duration(seconds: 5);

/// 回到前台后距上次成功同步至少多久才再同步
const Duration syncResumeMinInterval = Duration(minutes: 2);

/// 冷启动后这段时间内的 resumed 事件不算「回到前台」。
///
/// 安卓冷启动会补发一次 resumed; 那时首屏刚起来, 如果按「回到前台」处理就会
/// 绕过 [syncStartupDelay] 立刻开始同步 —— 4.10.2 的启动崩溃就是这样在
/// 启动 1.3 秒就进到合并阶段的。这段时间内忽略 resumed, 交给首屏稳定后的定时器。
const Duration syncColdStartResumeIgnore = Duration(seconds: 12);

/// 冷启动自动同步: 首屏渲染完成后延迟多久再跑。
/// 避免和首屏查询 + 详情页加载抢同一个 sqlite 连接。
const Duration syncStartupDelay = Duration(seconds: 5);

/// 启动安全阀: 进 init 时写 'starting', 首屏渲染完成后改成 'ok'。
/// 下次启动发现还是 'starting' 就说明上一次启动没走到首屏, 本次跳过自动同步。
const String syncLaunchGuardStarting = 'starting';
const String syncLaunchGuardOk = 'ok';

/// 删除墓碑保留时长, 超过后清理
const Duration syncTombstoneRetention = Duration(days: 90);

/// 参与设备快照的文件清单 (不含 cookies.db, 登录态各设备独立; 也不含下载目录)
List<String> syncSnapshotFileNames() => const [
      syncAppdataFileName,
      syncSettingsMetaFileName,
      syncHistoryDbFileName,
      syncLocalFavoritesDbFileName,
      syncReadPositionsFileName,
      syncManifestFileName,
    ];

/// 旧格式快照名: `<unix 秒>.picadata`
bool isLegacySnapshotName(String name) {
  if (!name.endsWith(syncSnapshotSuffix)) {
    return false;
  }
  return int.tryParse(name.split('.').first) != null;
}

/// 从旧格式文件名里取出 unix 秒, 不是旧格式返回 null
int? legacySnapshotVersion(String name) {
  if (!name.endsWith(syncSnapshotSuffix)) {
    return null;
  }
  return int.tryParse(name.split('.').first);
}

String deviceSnapshotName(String deviceId) => '$deviceId$syncSnapshotSuffix';

/// 从 `<deviceId>.picadata` 取出 deviceId, 不是设备快照返回 null
String? deviceIdFromSnapshotName(String name) {
  if (!name.endsWith(syncSnapshotSuffix) || isLegacySnapshotName(name)) {
    return null;
  }
  final id = name.substring(0, name.length - syncSnapshotSuffix.length);
  return id.isEmpty ? null : id;
}

String syncDevicePath(String deviceId) =>
    '$syncDevicesDirName/${deviceSnapshotName(deviceId)}';

String sha256OfBytes(List<int> bytes) => sha256.convert(bytes).toString();

String sha256OfFile(String path) => sha256OfFileSync(File(path));

String sha256OfFileSync(File file) => sha256.convert(file.readAsBytesSync()).toString();

/// 一台设备上一次同步后记录的远端状态, 用于跳过没变化的快照
class SyncDeviceState {
  String? eTag;

  String? hash;

  int? size;

  int? updatedAt;

  SyncDeviceState({this.eTag, this.hash, this.size, this.updatedAt});

  factory SyncDeviceState.fromJson(Map<String, dynamic> json) => SyncDeviceState(
        eTag: json['eTag'] as String?,
        hash: json['hash'] as String?,
        size: (json['size'] as num?)?.toInt(),
        updatedAt: (json['updatedAt'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        if (eTag != null) 'eTag': eTag,
        if (hash != null) 'hash': hash,
        if (size != null) 'size': size,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };
}

/// 合并计数, 展示在设置页并用 Sync: 前缀写日志
class SyncStats {
  int inserted = 0;

  int updated = 0;

  int deleted = 0;

  int skipped = 0;

  SyncStats();

  SyncStats.of(this.inserted, this.updated, this.deleted, this.skipped);

  bool get isEmpty => inserted == 0 && updated == 0 && deleted == 0;

  void add(SyncStats other) {
    inserted += other.inserted;
    updated += other.updated;
    deleted += other.deleted;
    skipped += other.skipped;
  }

  SyncStats clone() => SyncStats.of(inserted, updated, deleted, skipped);

  factory SyncStats.fromJson(Map<String, dynamic> json) => SyncStats.of(
        (json['inserted'] as num?)?.toInt() ?? 0,
        (json['updated'] as num?)?.toInt() ?? 0,
        (json['deleted'] as num?)?.toInt() ?? 0,
        (json['skipped'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'inserted': inserted,
        'updated': updated,
        'deleted': deleted,
        'skipped': skipped,
      };

  @override
  String toString() => '插入 $inserted · 更新 $updated · 删除 $deleted';
}

/// 本机同步状态, 保存在数据目录的 sync_state.json, 不参与同步
class SyncState {
  String deviceId;

  /// 上次成功同步时间(毫秒时间戳), 0 表示还没同步过
  int lastSyncAt;

  /// '' 从未同步 / 'ok' / 'failed' / 'skipped'
  String lastResult;

  String lastError;

  /// 是否已经把远端旧格式快照当作一次远端快照合并过
  bool legacySeeded;

  /// 启动安全阀标记: '' 从未记录 / 'starting' 启动中 / 'ok' 已到首屏
  String launchGuard;

  /// 本机快照最后写入时间
  int ownUpdatedAt;

  /// 各设备上次合并时的远端状态
  Map<String, SyncDeviceState> devices;

  SyncStats lastStats;

  /// 上次合并拉取到的设备列表
  List<String> pulledDevices;

  SyncState({
    required this.deviceId,
    this.lastSyncAt = 0,
    this.lastResult = '',
    this.lastError = '',
    this.legacySeeded = false,
    this.launchGuard = '',
    this.ownUpdatedAt = 0,
    Map<String, SyncDeviceState>? devices,
    SyncStats? lastStats,
    List<String>? pulledDevices,
  })  : devices = devices ?? <String, SyncDeviceState>{},
        lastStats = lastStats ?? SyncStats(),
        pulledDevices = pulledDevices ?? <String>[];

  factory SyncState.fromJson(Map<String, dynamic> json) {
    final devices = <String, SyncDeviceState>{};
    final rawDevices = json['devices'];
    if (rawDevices is Map) {
      for (final entry in rawDevices.entries) {
        final value = entry.value;
        if (value is Map) {
          devices[entry.key.toString()] =
              SyncDeviceState.fromJson(Map<String, dynamic>.from(value));
        }
      }
    }
    final rawStats = json['lastStats'];
    return SyncState(
      deviceId: json['deviceId'] as String? ?? '',
      lastSyncAt: (json['lastSyncAt'] as num?)?.toInt() ?? 0,
      lastResult: json['lastResult'] as String? ?? '',
      lastError: json['lastError'] as String? ?? '',
      legacySeeded: json['legacySeeded'] as bool? ?? false,
      launchGuard: json['launchGuard'] as String? ?? '',
      ownUpdatedAt: (json['ownUpdatedAt'] as num?)?.toInt() ?? 0,
      devices: devices,
      lastStats: rawStats is Map
          ? SyncStats.fromJson(Map<String, dynamic>.from(rawStats))
          : SyncStats(),
      pulledDevices: (json['pulledDevices'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[],
    );
  }

  static SyncState? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final json = jsonDecode(raw);
      if (json is! Map) {
        return null;
      }
      return SyncState.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'lastSyncAt': lastSyncAt,
        'lastResult': lastResult,
        'lastError': lastError,
        'legacySeeded': legacySeeded,
        'launchGuard': launchGuard,
        'ownUpdatedAt': ownUpdatedAt,
        'devices': {
          for (final entry in devices.entries) entry.key: entry.value.toJson(),
        },
        'lastStats': lastStats.toJson(),
        'pulledDevices': pulledDevices,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// 快照内 manifest.json 的内容
class SyncManifest {
  final int version;

  final String deviceId;

  /// 本快照写入时的毫秒时间戳, comic_source 等按内容取新的文件靠它判断先后
  final int updatedAt;

  /// 文件相对路径 -> sha256
  final Map<String, String> files;

  const SyncManifest({
    required this.version,
    required this.deviceId,
    required this.updatedAt,
    required this.files,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'deviceId': deviceId,
        'updatedAt': updatedAt,
        'files': files,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static SyncManifest? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final json = jsonDecode(raw);
      if (json is! Map) {
        return null;
      }
      final files = <String, String>{};
      final rawFiles = json['files'];
      if (rawFiles is Map) {
        for (final entry in rawFiles.entries) {
          files[entry.key.toString()] = entry.value.toString();
        }
      }
      return SyncManifest(
        version: (json['version'] as num?)?.toInt() ?? 0,
        deviceId: json['deviceId'] as String? ?? '',
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        files: files,
      );
    } catch (_) {
      return null;
    }
  }
}

/// settings_meta.json: {设置下标: 最近修改时间(毫秒)}
Map<int, int> decodeSettingsMeta(String? raw) {
  final meta = <int, int>{};
  if (raw == null || raw.trim().isEmpty) {
    return meta;
  }
  try {
    final json = jsonDecode(raw);
    if (json is! Map) {
      return meta;
    }
    for (final entry in json.entries) {
      final index = int.tryParse(entry.key.toString());
      final value = entry.value;
      if (index == null || value is! num) {
        continue;
      }
      meta[index] = value.toInt();
    }
  } catch (_) {
    meta.clear();
  }
  return meta;
}

String encodeSettingsMeta(Map<int, int> meta) => const JsonEncoder.withIndent('  ')
    .convert({for (final entry in meta.entries) entry.key.toString(): entry.value});
