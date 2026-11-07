import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/picacg_network/models.dart';

/// 一次浏览位置的快照: 看到第几页、最后一条的 id、当时的站点总页数,
/// 以及已浏览范围内每条作品的页数(用来判断作品本身有没有更新)
class BrowseAnchor {
  BrowseAnchor({
    required this.page,
    required this.lastId,
    required this.totalPages,
    required this.items,
    required this.time,
  });

  /// 上次加载/看到第几页(从 1 开始)
  int page;

  /// 上次最后一条的 id; 排序会漂移的列表(最多喜欢/最多指名)靠它定位
  String? lastId;

  /// 上次记录时站点的总页数
  int totalPages;

  /// 已浏览范围内 id -> 作品页数, 拿不到页数的源记 -1
  Map<String, int> items;

  int time;

  Map<String, dynamic> toJson() => {
        "page": page,
        "lastId": lastId,
        "totalPages": totalPages,
        "items": items,
        "time": time,
      };

  static BrowseAnchor? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return BrowseAnchor(
        page: (json["page"] as num).toInt(),
        lastId: json["lastId"] as String?,
        totalPages: (json["totalPages"] as num?)?.toInt() ?? 0,
        items: {
          for (final entry in (json["items"] as Map? ?? {}).entries)
            entry.key.toString(): (entry.value as num).toInt(),
        },
        time: (json["time"] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 浏览位置的本机存储: 一个筛选组合(源|分类|排序|多维度签名)一条记录
class BrowseAnchorStore {
  BrowseAnchorStore._();

  static final BrowseAnchorStore instance = BrowseAnchorStore._();

  /// 最多保留多少个组合, 超出淘汰最久没动的
  static const int maxRecords = 50;

  /// 单条记录最多保存多少条作品(约 20 页), 防止文件无限膨胀
  static const int maxItems = 400;

  final Map<String, BrowseAnchor> _records = {};

  bool _loaded = false;

  Timer? _saveTimer;

  File get _file => File("${App.dataPath}/browse_anchor.json");

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!_file.existsSync()) return;
      var json = jsonDecode(_file.readAsStringSync());
      if (json is! Map) return;
      for (final entry in json.entries) {
        var record = BrowseAnchor.fromJson(entry.value);
        if (record != null) _records[entry.key.toString()] = record;
      }
    } catch (_) {
      // 存储损坏时按空处理, 不影响页面
      _records.clear();
    }
  }

  BrowseAnchor? operator [](String key) {
    _load();
    return _records[key];
  }

  /// 记录当前浏览位置; 与上次完全相同时直接返回, 不写盘
  void record(
    String key, {
    required int page,
    String? lastId,
    required int totalPages,
    required Map<String, int> items,
  }) {
    _load();
    var old = _records[key];
    if (old != null &&
        old.page == page &&
        old.lastId == lastId &&
        old.totalPages == totalPages) {
      return;
    }
    var trimmed = items;
    if (items.length > maxItems) {
      var keys = items.keys.toList();
      trimmed = {
        for (final id in keys.sublist(keys.length - maxItems)) id: items[id]!,
      };
    }
    _records[key] = BrowseAnchor(
      page: page,
      lastId: lastId,
      totalPages: totalPages,
      items: trimmed,
      time: DateTime.now().millisecondsSinceEpoch,
    );
    _trim();
    _scheduleSave();
  }

  void _trim() {
    if (_records.length <= maxRecords) return;
    var keys = _records.keys.toList()
      ..sort((a, b) => _records[a]!.time.compareTo(_records[b]!.time));
    for (final key in keys.take(_records.length - maxRecords)) {
      _records.remove(key);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), save);
  }

  void save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      _file.writeAsStringSync(jsonEncode({
        for (final entry in _records.entries) entry.key: entry.value.toJson(),
      }));
    } catch (_) {
      // 写盘失败不影响使用
    }
  }
}

/// 上次记录与当前列表的差异
class AnchorDiff {
  AnchorDiff({
    this.addedPages = 0,
    this.addedCount = 0,
    this.updatedCount = 0,
    this.fromPageDiff = false,
  });

  /// 站点总页数增量, 旧到新排序下即尾部新增的页数
  int addedPages;

  /// 新增作品数; [fromPageDiff] 为 true 时是按页数差推算的估算值
  int addedCount;

  /// 已浏览范围内页数变多了的作品数
  int updatedCount;

  /// [addedCount] 是否由总页数差估算得来
  bool fromPageDiff;

  bool get isEmpty => addedPages == 0 && addedCount == 0 && updatedCount == 0;
}

/// 作品页数; 目前只有哔咔的列表条目带这个字段
int? comicPageCount(BaseComic comic) {
  if (comic is ComicItemBrief) return comic.pages;
  return null;
}

/// 比较上次快照与当前已加载的条目, 算出「新增作品」与「作品更新」
///
/// [stableOrder] 对应「旧到新」这类只往尾部追加的排序: 新作品不会挤进
/// 已浏览范围, 只能用站点总页数差来算; 其余排序(最多喜欢/最多指名)靠 id 集合差
AnchorDiff computeAnchorDiff({
  required BrowseAnchor old,
  required List<BaseComic> loaded,
  required int? totalPages,
  required bool stableOrder,
}) {
  var diff = AnchorDiff();
  for (final comic in loaded) {
    var before = old.items[comic.id];
    var now = comicPageCount(comic);
    if (before != null && before > 0 && now != null && now > before) {
      diff.updatedCount++;
    }
  }
  if (stableOrder) {
    var now = totalPages ?? 0;
    if (old.totalPages > 0 && now > old.totalPages) {
      diff.addedPages = now - old.totalPages;
      var perPage = 20;
      if (loaded.isNotEmpty && old.page > 0) {
        var avg = (loaded.length / old.page).ceil();
        if (avg > 0) perPage = avg;
      }
      diff.addedCount = diff.addedPages * perPage;
      diff.fromPageDiff = true;
    }
  } else {
    for (final comic in loaded) {
      if (!old.items.containsKey(comic.id)) diff.addedCount++;
    }
  }
  return diff;
}
