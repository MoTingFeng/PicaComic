import 'dart:async';
import 'dart:io';

import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/sync/sync_merge.dart';

/// 每话各自的阅读页码: 作品 -> (话号 -> 页号)。
///
/// 历史记录里只有一个当前位置, 这里补上「每一话停在哪一页」,
/// 这样点任意一话都能回到那一话上次停下的地方, 而不是从头开始。
/// 数据独立存放, 不进历史表; WebDAV 同步时按 target+话号 合并,
/// 所以每话额外记一个 updatedAt (旧文件没有, 读出来按 0 处理)。
class ReadPositionStore {
  ReadPositionStore._();

  static final ReadPositionStore instance = ReadPositionStore._();

  /// 最多保留多少个作品, 超出淘汰最久没读的
  static const int maxTargets = 200;

  /// 单个作品最多保留多少话
  static const int maxEps = 500;

  final Map<String, Map<int, int>> _data = {};

  /// 作品 -> (话号 -> 写入时间), 供同步合并判断谁更新
  final Map<String, Map<int, int>> _time = {};

  /// 作品最近一次写入时间, 用于淘汰
  final Map<String, int> _touch = {};

  bool _loaded = false;

  Timer? _saveTimer;

  /// 本地写入后回调, 用于触发 WebDAV 防抖上传
  void Function()? onChanged;

  File get _file => File("${App.dataPath}/read_positions.json");

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!_file.existsSync()) return;
      final positions = parseReadPositions(_file.readAsStringSync());
      for (final entry in positions.entries) {
        var newest = 0;
        final times = <int, int>{};
        for (final ep in entry.value.entries) {
          times[ep.key] = ep.value.updatedAt;
          if (ep.value.updatedAt > newest) {
            newest = ep.value.updatedAt;
          }
        }
        if (entry.value.isEmpty) continue;
        _data[entry.key] = {
          for (final ep in entry.value.entries) ep.key: ep.value.page,
        };
        _time[entry.key] = times;
        _touch[entry.key] = newest;
      }
    } catch (_) {
      _data.clear();
      _time.clear();
    }
  }

  /// 某一话上次停在第几页; 没记录返回 null
  int? pageOf(String target, int ep) {
    _load();
    return _data[target]?[ep];
  }

  /// 某个作品下所有话的页码
  Map<int, int> pagesOf(String target) {
    _load();
    var pages = _data[target];
    if (pages == null) return const {};
    return Map.unmodifiable(pages);
  }

  /// 记录某一话读到第几页; 与已有值相同则不写盘
  void save(String target, int ep, int page) {
    if (target.isEmpty || ep <= 0 || page <= 0) return;
    _load();
    var pages = _data.putIfAbsent(target, () => {});
    if (pages[ep] == page) return;
    pages[ep] = page;
    final now = DateTime.now().millisecondsSinceEpoch;
    _time.putIfAbsent(target, () => {})[ep] = now;
    if (pages.length > maxEps) {
      var keys = pages.keys.toList()..sort();
      for (final key in keys.take(pages.length - maxEps)) {
        pages.remove(key);
        _time[target]?.remove(key);
      }
    }
    _touch[target] = now;
    _trim();
    _scheduleSave();
    onChanged?.call();
  }

  void _trim() {
    if (_data.length <= maxTargets) return;
    var keys = _data.keys.toList()
      ..sort((a, b) => (_touch[a] ?? 0).compareTo(_touch[b] ?? 0));
    for (final key in keys.take(_data.length - maxTargets)) {
      _data.remove(key);
      _time.remove(key);
      _touch.remove(key);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), saveToFile);
  }

  void saveToFile() {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      _file.writeAsStringSync(encodeReadPositions(_export()));
    } catch (_) {
      // 写盘失败不影响阅读
    }
  }

  ReadPositions _export() => {
        for (final entry in _data.entries)
          entry.key: {
            for (final e in entry.value.entries)
              e.key: ReadPositionEntry(e.value, _time[entry.key]?[e.key] ?? 0),
          },
      };

  /// 导出全部阅读位置给同步合并用
  ReadPositions exportForSync() {
    _load();
    return _export();
  }

  /// 同步合并后把合并结果整体应用到内存与文件
  void applyMerged(ReadPositions merged) {
    _load();
    _data.clear();
    _time.clear();
    _touch.clear();
    for (final entry in merged.entries) {
      if (entry.value.isEmpty) continue;
      var newest = 0;
      final times = <int, int>{};
      for (final ep in entry.value.entries) {
        times[ep.key] = ep.value.updatedAt;
        if (ep.value.updatedAt > newest) {
          newest = ep.value.updatedAt;
        }
      }
      _data[entry.key] = {
        for (final ep in entry.value.entries) ep.key: ep.value.page,
      };
      _time[entry.key] = times;
      _touch[entry.key] = newest;
    }
    _trim();
    saveToFile();
  }
}
