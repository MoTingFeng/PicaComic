import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/tools/title_matching.dart';
import 'package:pica_comic/tools/translations.dart';

/// 一条跨源搜索结果
class _Hit {
  _Hit(this.source, this.comic, this.score, this.authorHit);

  final ComicSource source;
  final BaseComic comic;
  final double score;
  final bool authorHit;

  String get badge {
    if (score >= 0.95) {
      return "同名".tl;
    }
    if (authorHit && score < 0.6) {
      return "作者命中".tl;
    }
    return "标题相近".tl;
  }
}

enum _GroupStatus { waiting, searching, done, error }

class _Group {
  _Group(this.source);

  final ComicSource source;
  _GroupStatus status = _GroupStatus.waiting;
  final Map<String, _Hit> hits = {};
  String? error;

  List<_Hit> get sorted => hits.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  double get bestScore => sorted.isEmpty ? 0 : sorted.first.score;
}

class _Query {
  _Query(this.label, this.value);

  final String label;
  final String value;
  bool enabled = true;
}

/// 「在其他源搜索」侧页: 用当前作品的名字/节选/作者去已启用的其它源搜一遍。
class SearchOtherSourcesPanel extends StatefulWidget {
  const SearchOtherSourcesPanel({
    super.key,
    required this.sourceKey,
    required this.titleLoader,
    this.subTitleLoader,
    this.tagsLoader,
  });

  final String sourceKey;

  /// 这些值来自 BaseComicPage 的 getter, 依赖页面逻辑(StateController)。
  /// Scaffold 的 endDrawer 参数是在 StateBuilder 之外求值的, 这里必须惰性读取,
  /// 否则页面逻辑还没注册就会抛 "ComicPageLogic ... Not Found"。
  final String Function() titleLoader;
  final String? Function()? subTitleLoader;
  final Map<String, List<String>>? Function()? tagsLoader;

  @override
  State<SearchOtherSourcesPanel> createState() =>
      _SearchOtherSourcesPanelState();
}

class _SearchOtherSourcesPanelState extends State<SearchOtherSourcesPanel> {
  late List<_Query> _queries;
  late String _title;
  String? _subTitle;
  Map<String, List<String>>? _tags;
  late String? _authorRaw;
  final _manualController = TextEditingController();
  String? _manualQuery;

  final Map<String, _Group> _groups = {};
  bool _searching = false;
  bool _showWeak = false;
  int _doneSources = 0;
  int _totalSources = 0;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _title = widget.titleLoader();
    _subTitle = widget.subTitleLoader?.call();
    _tags = widget.tagsLoader?.call();
    _authorRaw = _resolveAuthor();
    _buildQueries();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  /// 作者在各地的存放位置不同: 先看副标题, 再在标签里按常见键名找
  String? _resolveAuthor() {
    var sub = _subTitle?.trim();
    if (sub != null && sub.isNotEmpty && !sub.contains("http")) {
      return sub;
    }
    var tags = _tags;
    if (tags == null) {
      return null;
    }
    for (var key in const [
      "作者",
      "Artists",
      "Artist",
      "author",
      "artist",
      "画师",
      "畫師",
    ]) {
      var values = tags[key];
      if (values != null && values.isNotEmpty) {
        return values.join("/");
      }
    }
    for (var entry in tags.entries) {
      var key = entry.key.toLowerCase();
      if ((key.contains("作者") ||
              key.contains("artist") ||
              key.contains("author") ||
              key.contains("画师")) &&
          entry.value.isNotEmpty) {
        return entry.value.join("/");
      }
    }
    return null;
  }

  void _buildQueries() {
    var title = normalizeTitle(_title);
    var fragment = fragmentTitle(_title);
    var authors = splitAuthors(_authorRaw);
    _queries = [
      if (title.isNotEmpty) _Query("标题".tl, title),
      if (fragment.isNotEmpty && fragment != title) _Query("节选".tl, fragment),
      for (var author in authors.take(2)) _Query("作者".tl, author),
    ];
    if (_queries.isEmpty) {
      _queries = [_Query("标题".tl, _title.trim())];
    }
  }

  List<String> _activeQueries() {
    if (_manualQuery != null && _manualQuery!.trim().isNotEmpty) {
      return [_manualQuery!.trim()];
    }
    var list = _queries
        .where((e) => e.enabled && e.value.trim().isNotEmpty)
        .map((e) => e.value)
        .toList();
    if (list.isEmpty) {
      list = [_queries.first.value];
    }
    return list;
  }

  List<ComicSource> _candidates() {
    return ComicSource.sources
        .where((source) =>
            source.key != widget.sourceKey &&
            source.searchPageData?.loadPage != null)
        .toList();
  }

  Future<void> _run() async {
    if (!mounted) {
      return;
    }
    var token = ++_token;
    var candidates = _candidates();
    setState(() {
      _groups.clear();
      for (var source in candidates) {
        _groups[source.key] = _Group(source);
      }
      _totalSources = candidates.length;
      _doneSources = 0;
      _searching = candidates.isNotEmpty;
    });
    if (candidates.isEmpty) {
      return;
    }
    var queue = List<ComicSource>.from(candidates);
    // 源之间并发 3: 再多容易触发源站风控, 自定义源的 JS 搜索也只能排队
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (token != _token) {
          return;
        }
        var source = queue.removeAt(0);
        await _searchSource(source, token);
        if (!mounted || token != _token) {
          return;
        }
        setState(() => _doneSources++);
      }
    }

    await Future.wait(List.generate(min(3, candidates.length), (_) => worker()));
    if (!mounted || token != _token) {
      return;
    }
    setState(() => _searching = false);
  }

  Future<void> _searchSource(ComicSource source, int token) async {
    var group = _groups[source.key]!;
    var data = source.searchPageData!;
    var options =
        data.searchOptions?.map((e) => e.defaultValue).toList() ?? <String>[];
    setState(() => group.status = _GroupStatus.searching);
    var queries = _activeQueries();
    String? error;
    for (var query in queries) {
      if (token != _token || !mounted) {
        return;
      }
      try {
        var res = await data
            .loadPage!(query, 1, options)
            .timeout(const Duration(seconds: 8));
        if (res.error) {
          error ??= res.errorMessageWithoutNull;
          continue;
        }
        error = null;
        for (var comic in res.dataOrNull ?? const <BaseComic>[]) {
          var hit = _score(comic, source);
          var exists = group.hits[comic.id];
          if (exists == null || hit.score > exists.score) {
            group.hits[comic.id] = hit;
          }
        }
        // 已经找到很像的结果, 就不用再拿节选/作者去试了
        var best = group.bestScore;
        if (best >= 0.9 ||
            group.sorted.any((e) => e.authorHit && e.score >= 0.55)) {
          break;
        }
      } catch (e) {
        error ??= e.toString();
      }
    }
    if (!mounted || token != _token) {
      return;
    }
    setState(() {
      group.error = error;
      group.status = error != null && group.hits.isEmpty
          ? _GroupStatus.error
          : _GroupStatus.done;
    });
  }

  _Hit _score(BaseComic comic, ComicSource source) {
    var score = titleSimilarity(_title, comic.title);
    var authorHit = false;
    var authors = splitAuthors(_authorRaw);
    if (authors.isNotEmpty) {
      var haystack = "${comic.subTitle} ${comic.tags.join(" ")}";
      for (var author in authors) {
        if (haystack.contains(author)) {
          authorHit = true;
          score = min(1.0, score + 0.2);
          break;
        }
      }
    }
    return _Hit(source, comic, score, authorHit);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: min(380, MediaQuery.of(context).size.width * 0.88),
      child: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              _buildQueryRow(context),
              _buildManualRow(context),
              if (_searching)
                LinearProgressIndicator(
                  value:
                      _totalSources == 0 ? null : _doneSources / _totalSources,
                  minHeight: 2,
                ),
              Expanded(child: _buildResults(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("在其他源搜索".tl,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: "关闭".tl,
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildQueryRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < _queries.length; i++)
            FilterChip(
              label: Text(
                _queries[i].label == _queries[i].value
                    ? _queries[i].label
                    : "${_queries[i].label}: ${_queries[i].value}",
                overflow: TextOverflow.ellipsis,
              ),
              selected: _queries[i].enabled,
              onSelected: (value) {
                setState(() {
                  _queries[i].enabled = value;
                  _manualQuery = null;
                  _manualController.clear();
                });
                _run();
              },
            ),
          if (_searching || _doneSources < _totalSources)
            Text(
              "${"已搜".tl} $_doneSources/$_totalSources",
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _buildManualRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: TextField(
        controller: _manualController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          hintText: "名字不一样? 手动输入关键词".tl,
          suffixIcon: _manualQuery == null
              ? const Icon(Icons.search)
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    setState(() {
                      _manualQuery = null;
                      _manualController.clear();
                    });
                    _run();
                  },
                ),
        ),
        onSubmitted: (value) {
          var query = value.trim();
          setState(() => _manualQuery = query.isEmpty ? null : query);
          _run();
        },
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    var groups = _groups.values.toList();
    if (groups.isEmpty) {
      return Center(child: Text("没有可搜索的其它源".tl));
    }
    groups.sort((a, b) {
      var byScore = b.bestScore.compareTo(a.bestScore);
      return byScore != 0 ? byScore : a.source.name.compareTo(b.source.name);
    });
    var maxHits = _showWeak ? 20 : 6;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (var group in groups) ...[
          _buildGroupHeader(context, group),
          if (group.hits.isNotEmpty)
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 0.62,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              children: [
                for (var hit in _visibleHits(group, maxHits))
                  Stack(
                    children: [
                      Positioned.fill(
                        child: buildComicTile(
                            context, hit.comic, group.source.key),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.65),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            hit.badge,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
        ],
        if (_groups.values.any((g) => g.hits.isNotEmpty))
          Center(
            child: TextButton(
              onPressed: () => setState(() => _showWeak = !_showWeak),
              child: Text(_showWeak ? "只显示相近的".tl : "显示更多结果".tl),
            ),
          ),
      ],
    );
  }

  List<_Hit> _visibleHits(_Group group, int maxHits) {
    var hits = group.sorted;
    if (!_showWeak) {
      hits = hits.where((e) => e.score >= 0.35).toList();
    }
    return hits.take(maxHits).toList();
  }

  Widget _buildGroupHeader(BuildContext context, _Group group) {
    var hits = _visibleHits(group, 1000);
    String status;
    switch (group.status) {
      case _GroupStatus.waiting:
        status = "等待".tl;
      case _GroupStatus.searching:
        status = "搜索中…".tl;
      case _GroupStatus.error:
        status = "没有响应".tl;
      case _GroupStatus.done:
        status = hits.isEmpty ? "无结果".tl : "${hits.length} ${"条".tl}";
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              group.source.name,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (group.status == _GroupStatus.searching)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(status, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
