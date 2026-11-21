import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/foundation/read_positions.dart';
import 'package:pica_comic/foundation/sync/sync_merge.dart';
import 'package:pica_comic/network/webdav.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:uuid/uuid.dart';

/// 一次同步的结果, 供设置页展示
class SyncResult {
  final bool success;

  /// true 表示没有需要合并的远端快照(只重写了本机快照), 不算失败
  final bool skipped;

  final String? error;

  final SyncStats stats;

  final List<String> pullDevices;

  const SyncResult._(
      this.success, this.skipped, this.stats, this.pullDevices, this.error);

  factory SyncResult.success({
    required SyncStats stats,
    required List<String> pullDevices,
    bool skipped = false,
  }) =>
      SyncResult._(true, skipped, stats, pullDevices, null);

  factory SyncResult.failure(String error) =>
      SyncResult._(false, false, SyncStats(), const [], error);

  factory SyncResult.notConfigured() =>
      SyncResult._(true, true, SyncStats(), const [], '未配置 WebDAV');

  factory SyncResult.busy() =>
      SyncResult._(true, true, SyncStats(), const [], '同步进行中');
}

class _RemoteCandidate {
  final String deviceId;

  final String? eTag;

  final int? size;

  final DateTime? mTime;

  _RemoteCandidate(this.deviceId, this.eTag, this.size, this.mTime);
}

class _RemoteSnapshot {
  final String deviceId;

  final String dir;

  final String hash;

  final SyncManifest? manifest;

  final int updatedAt;

  final String? eTag;

  final int? size;

  _RemoteSnapshot({
    required this.deviceId,
    required this.dir,
    required this.hash,
    required this.manifest,
    required this.updatedAt,
    required this.eTag,
    required this.size,
  });
}

/// WebDAV 多设备同步:
/// - 每台设备把自己的数据打包成 devices/<deviceId>.picadata;
/// - 同步时 PROPFIND 列出所有设备快照, 跳过上次同步后没变的, 其余下载解压后合并到本地;
/// - 合并完重写自己的快照并更新 sync_state.json;
/// - cookies.db 不参与同步, 设备相关设置不参与合并。
///
/// 失败不再自动禁用同步 (旧实现在设置尾部追加 ";0"), 合并失败会用备份还原。
class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  SyncState _state = SyncState(deviceId: '');

  SyncState get state => _state;

  Map<int, int> _settingsMeta = {};

  List<String> _settingsBaseline = [];

  Timer? _uploadTimer;

  /// 首屏渲染完成后的冷启动同步延时器
  Timer? _startupTimer;

  /// 上次启动写了 'starting' 却没走到首屏(异常退出): 本次不自动同步
  bool _previousLaunchUnclean = false;

  bool _syncing = false;

  bool _pendingUpload = false;

  bool _initialized = false;

  File get _stateFile => File('${App.dataPath}/sync_state.json');

  File get _settingsMetaFile =>
      File('${App.dataPath}/$syncSettingsMetaFileName');

  bool get isConfigured => WebdavConfig.tryParse(appdata.settings[45]) != null;

  bool get isSyncing => _syncing;

  /// App 启动、数据加载完之后调用一次
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    try {
      final metaFile = _settingsMetaFile;
      if (metaFile.existsSync()) {
        _settingsMeta = decodeSettingsMeta(metaFile.readAsStringSync());
      }
      _settingsBaseline = List<String>.from(appdata.settings);
      final stateFile = _stateFile;
      _state = (stateFile.existsSync()
              ? SyncState.tryParse(stateFile.readAsStringSync())
              : null) ??
          SyncState(deviceId: '');
      if (_state.deviceId.isEmpty) {
        _state.deviceId = const Uuid().v4();
      }
      // 启动安全阀: sync_state 里还是 'starting' 说明上次启动没走到首屏就退出了
      _previousLaunchUnclean = _state.launchGuard == syncLaunchGuardStarting;
      _state.launchGuard = syncLaunchGuardStarting;
      await _saveState();
      ReadPositionStore.instance.onChanged = markDirty;
      LogManager.addLog(LogLevel.info, 'Sync',
          'Sync: init deviceId=${_state.deviceId} lastSync=${_state.lastSyncAt} previousLaunchUnclean=$_previousLaunchUnclean');
      if (_previousLaunchUnclean) {
        LogManager.addLog(LogLevel.warning, 'Sync',
            'Sync: 上次启动未到首屏就退出(launchGuard 仍是 starting), 本次跳过自动同步, 手动同步不受影响');
      }
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Sync', 'Sync: init 失败\n$e\n$s');
    }
  }

  /// 首屏渲染完成后调用 (main.dart): 把启动标记改成 ok。
  /// 下次启动读到的就不是 'starting', 不会误判成异常退出。
  Future<void> markLaunchOk() async {
    await init();
    if (_state.launchGuard == syncLaunchGuardOk) {
      return;
    }
    _state.launchGuard = syncLaunchGuardOk;
    await _saveState();
    LogManager.addLog(
        LogLevel.info, 'Sync', 'Sync: launchGuard=ok (首屏已渲染)');
  }

  /// 冷启动自动同步: 首屏渲染完成后再延迟 [syncStartupDelay] 秒,
  /// 避免和首屏查询/详情页加载同时打本地数据库。
  /// 上次启动异常退出(launchGuard 仍是 starting)时本次跳过。
  void onAppStarted() {
    if (!isConfigured) {
      return;
    }
    if (_previousLaunchUnclean) {
      LogManager.addLog(LogLevel.warning, 'Sync',
          'Sync: 上次启动异常退出, 本次不自动同步(设置页可手动同步)');
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startupTimer?.cancel();
      _startupTimer = Timer(syncStartupDelay, () {
        _startupTimer = null;
        if (!isConfigured) {
          return;
        }
        LogManager.addLog(
            LogLevel.info,
            'Sync',
            'Sync: 首屏稳定 ${syncStartupDelay.inSeconds}s, 开始自动同步');
        unawaited(_runStartupSync());
      });
    });
  }

  /// 自动同步期间也挂上启动标记: 如果同步把进程搞崩, 下次启动会看到
  /// starting 而跳过自动同步, 保证 App 至少能正常进首屏一次。
  Future<void> _runStartupSync() async {
    _state.launchGuard = syncLaunchGuardStarting;
    await _saveState();
    try {
      await syncNow();
    } finally {
      _state.launchGuard = syncLaunchGuardOk;
      await _saveState();
    }
  }

  /// 回到前台: 距上次成功同步超过 2 分钟才再同步。
  /// 上次启动异常退出时本次不自动同步 (设置页的手动同步不受影响)。
  void onAppResumed() {
    if (!isConfigured || _previousLaunchUnclean) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_state.lastSyncAt > 0 &&
        now - _state.lastSyncAt < syncResumeMinInterval.inMilliseconds) {
      return;
    }
    unawaited(syncNow());
  }

  /// 本地数据有变更: 防抖 5 秒后上传自己的设备快照
  void markDirty() {
    if (!_initialized || !isConfigured) {
      return;
    }
    if (_syncing) {
      _pendingUpload = true;
      return;
    }
    _uploadTimer?.cancel();
    _uploadTimer = Timer(syncUploadDebounce, () {
      _uploadTimer = null;
      unawaited(uploadNow());
    });
  }

  /// 记录本地设置项的修改时间, 供按项合并时判断谁更新
  void recordLocalChanges() {
    final settings = appdata.settings;
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (var i = 0; i < settings.length; i++) {
      if (i >= _settingsBaseline.length) {
        _settingsBaseline.add(settings[i]);
        continue;
      }
      if (_settingsBaseline[i] != settings[i]) {
        _settingsMeta[i] = now;
        _settingsBaseline[i] = settings[i];
        changed = true;
      }
    }
    if (changed) {
      _saveSettingsMeta();
    }
  }

  /// 立即上传自己的设备快照 (设置页/防抖计时器用)
  Future<bool> uploadNow({String? config}) async {
    await init();
    final cfg = WebdavConfig.tryParse(config ?? appdata.settings[45]);
    if (cfg == null) {
      return true;
    }
    if (_syncing) {
      _pendingUpload = true;
      return false;
    }
    _syncing = true;
    try {
      return await _uploadSnapshot(cfg);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Sync', 'Sync: 上传失败\n$e\n$s');
      _state.lastResult = 'failed';
      _state.lastError = 'upload: $e';
      await _saveState();
      return false;
    } finally {
      _syncing = false;
      if (_pendingUpload) {
        _pendingUpload = false;
        markDirty();
      }
    }
  }

  /// 完整同步: 拉取其它设备快照 -> 合并 -> 重写自己的快照
  Future<SyncResult> syncNow({String? config}) async {
    await init();
    final cfg = WebdavConfig.tryParse(config ?? appdata.settings[45]);
    if (cfg == null) {
      return SyncResult.notConfigured();
    }
    if (_syncing) {
      return SyncResult.busy();
    }
    _syncing = true;
    _uploadTimer?.cancel();
    _uploadTimer = null;
    final startedAt = DateTime.now();
    final stats = SyncStats();
    final pulled = <String>[];
    Directory? workDir;
    var backupDir = '';
    var mergeError = '';
    try {
      recordLocalChanges();
      ReadPositionStore.instance.saveToFile();

      var phaseStart = DateTime.now();
      final candidates = await _findCandidates(cfg);
      final legacyName = await _findLegacySnapshot(cfg);
      _logStage(
          '拉取远端设备列表 candidates=${candidates.length} legacy=${legacyName != null}',
          phaseStart);
      if (candidates.isEmpty && legacyName == null) {
        phaseStart = DateTime.now();
        final uploaded = await _uploadSnapshot(cfg);
        _logStage('没有新的远端快照, 重写本机快照', phaseStart);
        _state.lastSyncAt = DateTime.now().millisecondsSinceEpoch;
        _state.lastResult = uploaded ? 'ok' : 'failed';
        _state.pulledDevices = const [];
        _state.lastStats = SyncStats();
        await _saveState();
        LogManager.addLog(LogLevel.info, 'Sync', 'Sync: 没有新的远端快照, 已重写本机快照');
        return SyncResult.success(
            stats: SyncStats(), pullDevices: const [], skipped: true);
      }

      workDir = Directory('${App.cachePath}/sync_pull');
      if (workDir.existsSync()) {
        workDir.deleteSync(recursive: true);
      }
      workDir.createSync(recursive: true);

      final snapshots = <_RemoteSnapshot>[];
      for (var index = 0; index < candidates.length; index++) {
        final candidate = candidates[index];
        phaseStart = DateTime.now();
        snapshots.add(await _downloadSnapshot(
          cfg,
          '$syncDevicesDirName/${deviceSnapshotName(candidate.deviceId)}',
          candidate.deviceId,
          workDir,
          eTag: candidate.eTag,
          size: candidate.size,
          mTime: candidate.mTime,
        ));
        _logStage(
            '下载快照 ${index + 1}/${candidates.length} ${candidate.deviceId}',
            phaseStart);
      }
      if (legacyName != null) {
        phaseStart = DateTime.now();
        snapshots.add(await _downloadSnapshot(
          cfg,
          legacyName,
          'legacy',
          workDir,
          legacyVersion: legacySnapshotVersion(legacyName),
        ));
        _logStage('下载旧格式快照 $legacyName', phaseStart);
        LogManager.addLog(LogLevel.info, 'Sync',
            'Sync: 首次升级, 把旧格式快照 $legacyName 当作远端快照');
      }

      phaseStart = DateTime.now();
      backupDir = await _backupLocalData();
      _logStage('合并前备份', phaseStart);

      // sqlite 合并: 在本地已经打开的连接上 ATTACH 远端库做合并,
      // 全程不关闭/不重开 history.db 与 local_favorite.db
      final historyDb = HistoryManager().db;
      final favoritesDb = LocalFavoritesManager().db;
      phaseStart = DateTime.now();
      try {
        LogManager.addLog(
            LogLevel.info,
            'Sync',
            'Sync: 合并前 在已打开的本地连接上 ATTACH 合并 ${snapshots.length} 个远端快照');
        for (final snapshot in snapshots) {
          final deviceStart = DateTime.now();
          final historyStats = mergeHistoryDatabase(
            local: historyDb,
            remotePath: '${snapshot.dir}/$syncHistoryDbFileName',
            nowMs: DateTime.now().millisecondsSinceEpoch,
            log: (phase, ms) => LogManager.addLog(LogLevel.info, 'Sync',
                'Sync: history.db $phase ${snapshot.deviceId} 耗时 ${ms}ms'),
          );
          final favoriteStats = mergeLocalFavoritesDatabase(
            local: favoritesDb,
            remotePath: '${snapshot.dir}/$syncLocalFavoritesDbFileName',
            nowMs: DateTime.now().millisecondsSinceEpoch,
            log: (phase, ms) => LogManager.addLog(LogLevel.info, 'Sync',
                'Sync: local_favorite.db $phase ${snapshot.deviceId} 耗时 ${ms}ms'),
          );
          stats.add(historyStats);
          stats.add(favoriteStats);
          pulled.add(snapshot.deviceId);
          _logStage(
              '合并设备 ${snapshot.deviceId} 完成',
              deviceStart,
              extra: 'history[插 ${historyStats.inserted} 更 ${historyStats.updated} 删 ${historyStats.deleted}] '
                  'favorites[插 ${favoriteStats.inserted} 更 ${favoriteStats.updated} 删 ${favoriteStats.deleted}]');
        }
        _logStage('sqlite 合并全部完成', phaseStart);
      } catch (e, s) {
        mergeError = e.toString();
        // 每个快照的合并都在事务里, 失败时已 ROLLBACK, 本地连接没被动过;
        // 不再用文件级备份覆盖正在打开的数据库 (那样才是不安全的)
        LogManager.addLog(
            LogLevel.error, 'Sync', 'Sync: 合并失败(已回滚, 本地连接未关闭)\n$e\n$s');
      } finally {
        // 合并直接改了本地库, 缓存要作废; 连接没关, 不需要重开
        _refreshLocalCaches();
      }

      if (mergeError.isNotEmpty) {
        _state.lastResult = 'failed';
        _state.lastError = 'merge: $mergeError';
        _state.pulledDevices = pulled;
        _state.lastStats = stats.clone();
        await _saveState();
        LogManager.addLog(LogLevel.warning, 'Sync',
            'Sync: 同步失败(合并阶段), 已合并 ${pulled.length} 台设备, 合并前备份保留在 $backupDir');
        return SyncResult.failure(mergeError);
      }

      // 旧格式快照只需合并一次: sqlite 合并已落地就把 seed 标记立刻落盘,
      // 避免后面的上传/设置应用/漫画源步骤失败导致每次冷启动都重做一遍(实测 7.7s/次)
      if (legacyName != null && !_state.legacySeeded) {
        _state.legacySeeded = true;
        await _saveState();
        LogManager.addLog(
            LogLevel.info, 'Sync', 'Sync: 旧格式快照已合并, seed 标记已落盘');
      }

      // 阅读位置合并
      phaseStart = DateTime.now();
      var positions = ReadPositionStore.instance.exportForSync();
      for (final snapshot in snapshots) {
        final file = File('${snapshot.dir}/$syncReadPositionsFileName');
        final remotePositions = parseReadPositions(
            file.existsSync() ? file.readAsStringSync() : null);
        final result = mergeReadPositions(positions, remotePositions);
        stats.add(result.stats);
        positions = result.merged;
      }
      trimReadPositions(positions,
          maxTargets: ReadPositionStore.maxTargets,
          maxEps: ReadPositionStore.maxEps);
      ReadPositionStore.instance.applyMerged(positions);
      _logStage('合并阅读位置', phaseStart);

      // 设置与 appdata 合并
      phaseStart = DateTime.now();
      var settings = appdata.settings;
      var settingsMeta = _settingsMeta;
      var mergedAppdata = appdata.toJson();
      for (final snapshot in snapshots) {
        final appdataFile = File('${snapshot.dir}/$syncAppdataFileName');
        if (!appdataFile.existsSync()) {
          continue;
        }
        Map<String, dynamic> remoteAppdata;
        try {
          remoteAppdata = Map<String, dynamic>.from(
              jsonDecode(appdataFile.readAsStringSync()));
        } catch (_) {
          continue;
        }
        final metaFile = File('${snapshot.dir}/$syncSettingsMetaFileName');
        final remoteMeta = decodeSettingsMeta(
            metaFile.existsSync() ? metaFile.readAsStringSync() : null);
        final remoteSettings = remoteAppdata['settings'] is List
            ? List<String>.from(
                (remoteAppdata['settings'] as List).map((e) => e.toString()))
            : <String>[];
        final merged = mergeSettings(
          local: settings,
          localMeta: settingsMeta,
          remote: remoteSettings,
          remoteMeta: remoteMeta,
          excluded: syncExcludedSettingIndices.toSet(),
        );
        stats.updated += merged.updated;
        settings = merged.settings;
        settingsMeta = merged.meta;
        mergedAppdata = mergeAppdataJson(
          local: mergedAppdata,
          remote: remoteAppdata,
          settings: merged,
        );
      }
      if (snapshots.isNotEmpty) {
        // readDataFromJson 失败内部会把 appdata 回滚, 这里必须报失败而不是继续报"完成"
        final settingsApplied = appdata.readDataFromJson(mergedAppdata);
        if (!settingsApplied) {
          const error = '设置合并失败: Appdata.readDataFromJson 返回 false, 本轮设置未应用';
          LogManager.addLog(LogLevel.error, 'Sync', 'Sync: $error');
          _state.lastResult = 'failed';
          _state.lastError = error;
          _state.pulledDevices = pulled;
          _state.lastStats = stats.clone();
          await _saveState();
          return SyncResult.failure(error);
        }
        _settingsMeta = settingsMeta;
        _saveSettingsMeta();
        _settingsBaseline = List<String>.from(appdata.settings);
      }
      _logStage('合并设置与 appdata', phaseStart);

      // comic_source 按内容 hash 取新
      phaseStart = DateTime.now();
      var comicSourceChanged = false;
      for (final snapshot in snapshots) {
        final result = await _mergeComicSource(snapshot);
        stats.add(result);
        if (result.inserted + result.updated > 0) {
          comicSourceChanged = true;
        }
      }
      if (comicSourceChanged) {
        try {
          await ComicSource.reload();
        } catch (e, s) {
          LogManager.addLog(
              LogLevel.error, 'Sync', 'Sync: 重新加载漫画源失败\n$e\n$s');
        }
      }
      _logStage('合并漫画源 comicSourceChanged=$comicSourceChanged', phaseStart);

      // 重写自己的快照 + 记录各设备状态
      phaseStart = DateTime.now();
      final uploaded = await _uploadSnapshot(cfg);
      _logStage('重写本机快照(上传)', phaseStart);
      for (final snapshot in snapshots) {
        _state.devices[snapshot.deviceId] = SyncDeviceState(
          eTag: snapshot.eTag,
          hash: snapshot.hash,
          size: snapshot.size,
          updatedAt: snapshot.updatedAt,
        );
      }
      _state.lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      _state.lastResult = uploaded ? 'ok' : 'failed';
      _state.lastError = uploaded ? '' : 'upload failed';
      _state.pulledDevices = pulled;
      _state.lastStats = stats.clone();
      _pendingUpload = false;
      await _saveState();
      LogManager.addLog(
          LogLevel.info,
          'Sync',
          'Sync: 完成 拉取 ${pulled.length} 台设备, 插入 ${stats.inserted} 更新 ${stats.updated} '
              '删除 ${stats.deleted}, 耗时 ${DateTime.now().difference(startedAt).inMilliseconds}ms');
      return SyncResult.success(stats: stats, pullDevices: pulled);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Sync', 'Sync: 同步失败\n$e\n$s');
      _state.lastResult = 'failed';
      _state.lastError = e.toString();
      await _saveState();
      return SyncResult.failure(e.toString());
    } finally {
      if (workDir != null && workDir.existsSync()) {
        try {
          workDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      _syncing = false;
      if (_pendingUpload) {
        _pendingUpload = false;
        markDirty();
      }
    }
  }

  /// 设置页「立即同步」: 带加载框与结果提示
  Future<SyncResult> manualSync() async {
    await init();
    if (!isConfigured) {
      showToast(message: '请先填写 WebDAV 配置'.tl);
      return SyncResult.notConfigured();
    }
    final context = App.globalContext;
    final controller = context == null
        ? null
        : showLoadingDialog(
            context,
            barrierDismissible: false,
            allowCancel: true,
            message: '同步数据中'.tl,
            cancelButtonText: '隐藏'.tl,
          );
    try {
      final result = await syncNow();
      controller?.close();
      if (!result.success) {
        showToast(message: '同步失败: ${result.error ?? ''}'.tl);
      } else if (result.skipped) {
        showToast(message: '已上传本机数据, 没有新的远端数据'.tl);
      } else {
        showToast(message: '同步完成: ${result.stats}'.tl);
      }
      return result;
    } catch (e, s) {
      controller?.close();
      LogManager.addLog(LogLevel.error, 'Sync', 'Sync: 手动同步失败\n$e\n$s');
      showToast(message: '同步失败: $e'.tl);
      return SyncResult.failure(e.toString());
    }
  }

  /// 设置页展示用的状态文本
  String statusText() {
    if (!isConfigured) {
      return '未配置'.tl;
    }
    final last = _state.lastSyncAt;
    final time = last == 0
        ? '从未同步'.tl
        : DateTime.fromMillisecondsSinceEpoch(last)
            .toString()
            .substring(0, 19);
    final result = switch (_state.lastResult) {
      'ok' => '成功'.tl,
      'failed' => '失败: ${_state.lastError}'.tl,
      _ => '未同步'.tl,
    };
    final devices =
        _state.pulledDevices.isEmpty ? '无'.tl : _state.pulledDevices.join(', ');
    return '上次同步: $time\n结果: $result\n拉取设备: $devices\n'
        '合并计数: ${_state.lastStats}';
  }

  // -------------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------------

  Future<List<_RemoteCandidate>> _findCandidates(WebdavConfig cfg) async {
    List<dynamic> files;
    try {
      files = await Webdav.listDir(cfg, cfg.remotePath('$syncDevicesDirName'));
    } catch (_) {
      // 首次同步时 devices/ 还不存在(服务器返回 404), 当成没有设备快照:
      // 这里只留一句 info, 不再把 DioException 全量刷进日志
      LogManager.addLog(
          LogLevel.info, 'Sync', 'Sync: 远端还没有 devices/ 目录, 按无设备快照处理');
      return const [];
    }
    final candidates = <_RemoteCandidate>[];
    for (final file in files) {
      final name = file.name as String?;
      if (name == null || file.isDir == true) {
        continue;
      }
      final deviceId = deviceIdFromSnapshotName(name);
      if (deviceId == null || deviceId == _state.deviceId) {
        continue;
      }
      final known = _state.devices[deviceId];
      if (known != null &&
          _sameRemote(known, file.eTag as String?, file.size as int?,
              file.mTime as DateTime?)) {
        continue;
      }
      candidates.add(_RemoteCandidate(deviceId, file.eTag as String?,
          file.size as int?, file.mTime as DateTime?));
    }
    return candidates;
  }

  Future<String?> _findLegacySnapshot(WebdavConfig cfg) async {
    if (_state.legacySeeded) {
      return null;
    }
    final files = await Webdav.listDir(cfg, cfg.root);
    int? best;
    for (final file in files) {
      final name = file.name;
      if (name == null || file.isDir == true) {
        continue;
      }
      final version = legacySnapshotVersion(name);
      if (version != null && (best == null || version > best)) {
        best = version;
      }
    }
    return best == null ? null : '$best.picadata';
  }

  bool _sameRemote(
      SyncDeviceState known, String? eTag, int? size, DateTime? mTime) {
    if (known.eTag != null && eTag != null) {
      return known.eTag == eTag;
    }
    if (known.size != null &&
        known.updatedAt != null &&
        size != null &&
        mTime != null) {
      return known.size == size &&
          known.updatedAt == mTime.millisecondsSinceEpoch;
    }
    return false;
  }

  Future<_RemoteSnapshot> _downloadSnapshot(
    WebdavConfig cfg,
    String remoteRelativePath,
    String label,
    Directory workDir, {
    String? eTag,
    int? size,
    DateTime? mTime,
    int? legacyVersion,
  }) async {
    final zipPath = '${workDir.path}/$label.picadata';
    await Webdav.downloadFile(cfg, cfg.remotePath(remoteRelativePath), zipPath);
    final dir = '${workDir.path}/$label';
    await extractSyncSnapshot(zipPath, dir);
    final manifestFile = File('$dir/$syncManifestFileName');
    final manifest = SyncManifest.tryParse(
        manifestFile.existsSync() ? manifestFile.readAsStringSync() : null);
    final updatedAt = manifest?.updatedAt ??
        (legacyVersion != null
            ? legacyVersion * 1000
            : (mTime?.millisecondsSinceEpoch ?? 0));
    return _RemoteSnapshot(
      deviceId: label,
      dir: dir,
      hash: sha256OfFile(zipPath),
      manifest: manifest,
      updatedAt: updatedAt,
      eTag: eTag,
      size: size,
    );
  }

  Future<bool> _uploadSnapshot(WebdavConfig cfg) async {
    recordLocalChanges();
    ReadPositionStore.instance.saveToFile();
    final now = DateTime.now().millisecondsSinceEpoch;
    final outPath = '${App.cachePath}/sync_upload.picadata';
    await exportSyncSnapshot(
      outPath: outPath,
      deviceId: _state.deviceId,
      updatedAt: now,
      settingsMeta: _settingsMeta,
    );
    await Webdav.ensureDevicesDir(cfg);
    await Webdav.uploadFile(
        cfg, cfg.remotePath(syncDevicePath(_state.deviceId)), outPath);
    await Webdav.writeText(
      cfg,
      cfg.remotePath(syncStateRemoteFileName),
      const JsonEncoder.withIndent('  ').convert({
        'updatedAt': now,
        'writer': _state.deviceId,
        'version': syncProtocolVersion,
      }),
    );
    final file = File(outPath);
    _state.ownUpdatedAt = now;
    _state.devices[_state.deviceId] = SyncDeviceState(
      hash: sha256OfFile(outPath),
      size: file.existsSync() ? file.lengthSync() : null,
      updatedAt: now,
    );
    await _saveState();
    return true;
  }

  Future<SyncStats> _mergeComicSource(_RemoteSnapshot snapshot) async {
    final stats = SyncStats();
    final remoteDir = Directory('${snapshot.dir}/$syncComicSourceDirName');
    if (!remoteDir.existsSync()) {
      return stats;
    }
    final localDir = Directory('${App.dataPath}/$syncComicSourceDirName');
    if (!localDir.existsSync()) {
      localDir.createSync(recursive: true);
    }
    final remoteNewer = snapshot.updatedAt > _state.ownUpdatedAt;
    for (final entry in remoteDir.listSync()) {
      if (entry is! File) {
        continue;
      }
      final name = entry.uri.pathSegments.last;
      final localFile = File('${localDir.path}/$name');
      final remoteHash =
          snapshot.manifest?.files['$syncComicSourceDirName/$name'] ??
              sha256OfFile(entry.path);
      if (!localFile.existsSync()) {
        await entry.copy(localFile.path);
        stats.inserted++;
      } else if (sha256OfFile(localFile.path) == remoteHash) {
        stats.skipped++;
      } else if (remoteNewer) {
        try {
          localFile.copySync(
              '${localFile.path}.bak-sync-${DateTime.now().millisecondsSinceEpoch}');
        } catch (_) {}
        await entry.copy(localFile.path);
        stats.updated++;
        LogManager.addLog(
            LogLevel.info, 'Sync', 'Sync: comic_source/$name 用远端较新版本覆盖');
      } else {
        stats.skipped++;
      }
    }
    return stats;
  }

  Future<String> _backupLocalData() async {
    try {
      final root = Directory('${App.dataPath}/sync_backup');
      root.createSync(recursive: true);
      final dir =
          Directory('${root.path}/${DateTime.now().millisecondsSinceEpoch}');
      dir.createSync(recursive: true);
      for (final name in [
        syncHistoryDbFileName,
        syncLocalFavoritesDbFileName,
        syncReadPositionsFileName,
        'settings',
        syncSettingsMetaFileName,
      ]) {
        final file = File('${App.dataPath}/$name');
        if (file.existsSync()) {
          await file.copy('${dir.path}/$name');
        }
      }
      // 只保留最近 3 份备份
      final dirs = root.listSync().whereType<Directory>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final old in dirs.skip(3)) {
        try {
          old.deleteSync(recursive: true);
        } catch (_) {}
      }
      LogManager.addLog(LogLevel.info, 'Sync', 'Sync: 合并前备份到 ${dir.path}');
      return dir.path;
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Sync', 'Sync: 备份失败\n$e\n$s');
      return '';
    }
  }

  /// 同步阶段日志: 每条带耗时 ms
  void _logStage(String stage, DateTime since, {String extra = ''}) {
    final ms = DateTime.now().difference(since).inMilliseconds;
    LogManager.addLog(LogLevel.info, 'Sync',
        'Sync: $stage 耗时 ${ms}ms${extra.isEmpty ? '' : ' $extra'}');
  }

  /// 合并直接写了本地数据库: 只作废内存缓存并刷新界面, 不关闭/不重开连接
  void _refreshLocalCaches() {
    try {
      HistoryManager().refreshAfterSync();
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'Sync', 'Sync: 刷新历史缓存失败\n$e\n$s');
    }
    try {
      LocalFavoritesManager().refreshAfterSync();
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'Sync', 'Sync: 刷新收藏缓存失败\n$e\n$s');
    }
  }

  void _saveSettingsMeta() {
    try {
      _settingsMetaFile.writeAsStringSync(encodeSettingsMeta(_settingsMeta));
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'Sync', 'Sync: 写 settings_meta.json 失败\n$e\n$s');
    }
  }

  Future<void> _saveState() async {
    try {
      await _stateFile.writeAsString(_state.encode());
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, 'Sync', 'Sync: 写 sync_state.json 失败\n$e\n$s');
    }
  }
}
