import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 分类页上次选中的排序与多维筛选
///
/// 一个「源|分类|子分类」一条记录: [options] 与页面的 optionsValue 一一对应
/// (每组的选中 key), [groups] 的 key 是分组标题、值是该组选中的参数
/// (与多维度筛选 loader 的 groupParams 一致, null 表示该组未选)。
class CategoryOptions {
  CategoryOptions({
    required List<String> options,
    Map<String, String?> groups = const {},
  })  : options = List.unmodifiable(options),
        groups = Map.unmodifiable(groups);

  /// 每组选项选中的 key, 顺序与页面 optionsValue 一致
  final List<String> options;

  /// 多维筛选: 分组标题 -> 选中参数
  final Map<String, String?> groups;

  Map<String, dynamic> toJson() => {
        "options": options,
        "groups": groups,
      };

  static CategoryOptions? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      var rawOptions = json["options"];
      if (rawOptions is! List) return null;
      var groups = <String, String?>{};
      var rawGroups = json["groups"];
      if (rawGroups is Map) {
        for (final entry in rawGroups.entries) {
          var value = entry.value;
          if (value != null && value is! String) continue;
          groups[entry.key.toString()] = value as String?;
        }
      }
      return CategoryOptions(
        options: [
          for (final option in rawOptions)
            if (option is String) option else throw const FormatException(),
        ],
        groups: groups,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 把上次的选择套到当前页面的选项上: 仍然存在的值才恢复, 已失效的回退默认
///
/// [availableOptions] 是每组当前可选的 key, [defaultOptions] 是各组的默认值(第一项);
/// [availableGroups]/[defaultGroups] 对应多维筛选, 组不在页面上时直接忽略。
CategoryOptions resolveCategoryOptions({
  required CategoryOptions? saved,
  required List<List<String>> availableOptions,
  required List<String> defaultOptions,
  Map<String, List<String?>> availableGroups = const {},
  Map<String, String?> defaultGroups = const {},
}) {
  var options = List<String>.of(defaultOptions);
  var savedOptions = saved?.options ?? const <String>[];
  for (var i = 0; i < options.length && i < savedOptions.length; i++) {
    if (i < availableOptions.length &&
        availableOptions[i].contains(savedOptions[i])) {
      options[i] = savedOptions[i];
    }
  }
  var groups = Map<String, String?>.of(defaultGroups);
  var savedGroups = saved?.groups ?? const <String, String?>{};
  for (final key in groups.keys.toList()) {
    if (!savedGroups.containsKey(key)) continue;
    var allowed = availableGroups[key];
    if (allowed == null) continue;
    var value = savedGroups[key];
    if (value == null || allowed.contains(value)) {
      groups[key] = value;
    }
  }
  return CategoryOptions(options: options, groups: groups);
}

/// 分类页选择的本机存储: 一个「源|分类|子分类」一条记录
///
/// 路径由调用方注入(页面传 App.dataPath, 单测传临时目录), 所以这里是纯 dart:io
/// 实现, 不依赖 Flutter, 可以直接 dart run 测试。写入做 500ms 防抖。
class CategoryOptionsStore {
  CategoryOptionsStore(
    this.directory, {
    this.debounce = const Duration(milliseconds: 500),
  });

  /// 同一目录共享一个实例, 页面用这个取
  static CategoryOptionsStore of(String directory) =>
      _instances.putIfAbsent(directory, () => CategoryOptionsStore(directory));

  static final Map<String, CategoryOptionsStore> _instances = {};

  /// 存储所在目录(不含文件名)
  final String directory;

  /// 写入防抖间隔
  final Duration debounce;

  final Map<String, CategoryOptions> _records = {};

  bool _loaded = false;

  Timer? _saveTimer;

  File get file => File("$directory/category_options.json");

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!file.existsSync()) return;
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return;
      for (final entry in json.entries) {
        var record = CategoryOptions.fromJson(entry.value);
        if (record != null) _records[entry.key.toString()] = record;
      }
    } catch (_) {
      // 存储损坏时按空处理, 不影响页面
      _records.clear();
    }
  }

  CategoryOptions? operator [](String key) {
    _load();
    return _records[key];
  }

  /// 记住某个组合的选择; 与上次相同则不写盘
  void save(String key, CategoryOptions options) {
    _load();
    var old = _records[key];
    if (old != null && _same(old, options)) return;
    _records[key] = options;
    _saveTimer?.cancel();
    _saveTimer = Timer(debounce, flush);
  }

  /// 立即写盘(单测用; 正常流程走 [debounce] 防抖)
  void flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({
        for (final entry in _records.entries) entry.key: entry.value.toJson(),
      }));
    } catch (_) {
      // 写盘失败不影响使用
    }
  }

  static bool _same(CategoryOptions a, CategoryOptions b) {
    if (a.options.length != b.options.length) return false;
    for (var i = 0; i < a.options.length; i++) {
      if (a.options[i] != b.options[i]) return false;
    }
    if (a.groups.length != b.groups.length) return false;
    for (final entry in a.groups.entries) {
      if (!b.groups.containsKey(entry.key) || b.groups[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}
