import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pica_comic/foundation/app.dart';

/// 每话各自的阅读页码: 作品 -> (话号 -> 页号)。
///
/// 历史记录里只有一个当前位置, 这里补上「每一话停在哪一页」,
/// 这样点任意一话都能回到那一话上次停下的地方, 而不是从头开始。
/// 数据独立存放, 不进历史表也不参与云备份, 坏了只影响这一份位置。
class ReadPositionStore {
  ReadPositionStore._();

  static final ReadPositionStore instance = ReadPositionStore._();

  /// 最多保留多少个作品, 超出淘汰最久没读的
  static const int maxTargets = 200;

  /// 单个作品最多保留多少话
  static const int maxEps = 500;

  final Map<String, Map<int, int>> _data = {};

  /// 作品最近一次写入时间, 用于淘汰
  final Map<String, int> _touch = {};

  bool _loaded = false;

  Timer? _saveTimer;

  File get _file => File("${App.dataPath}/read_positions.json");

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!_file.existsSync()) return;
      var json = jsonDecode(_file.readAsStringSync());
      if (json is! Map) return;
      for (final entry in json.entries) {
        var value = entry.value;
        if (value is! Map) continue;
        var eps = <int, int>{};
        for (final e in value.entries) {
          var ep = int.tryParse(e.key.toString());
          if (ep == null) continue;
          if (e.value is num) eps[ep] = (e.value as num).toInt();
        }
        if (eps.isNotEmpty) _data[e.key.toString()] = eps;
      }
    } catch (_) {
      _data.clear();
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
    if (pages.length > maxEps) {
      var keys = pages.keys.toList()..sort();
      for (final key in keys.take(pages.length - maxEps)) {
        pages.remove(key);
      }
    }
    _touch[target] = DateTime.now().millisecondsSinceEpoch;
    _trim();
    _scheduleSave();
  }

  void _trim() {
    if (_data.length <= maxTargets) return;
    var keys = _data.keys.toList()
      ..sort((a, b) => (_touch[a] ?? 0).compareTo(_touch[b] ?? 0));
    for (final key in keys.take(_data.length - maxTargets)) {
      _data.remove(key);
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
      _file.writeAsStringSync(jsonEncode({
        for (final entry in _data.entries)
          entry.key: {
            for (final e in entry.value.entries) e.key.toString(): e.value,
          },
      }));
    } catch (_) {
      // 写盘失败不影响阅读
    }
  }
}
