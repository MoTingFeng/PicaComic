import "package:flutter/material.dart";
import "package:pica_comic/base.dart";
import "package:pica_comic/comic_source/comic_source.dart";
import 'package:pica_comic/components/components.dart';
import "package:pica_comic/foundation/app.dart";
import "package:pica_comic/foundation/browse_anchor.dart";
import "package:pica_comic/foundation/state_controller.dart";
import "package:pica_comic/network/base_comic.dart";
import "package:pica_comic/network/res.dart";
import "package:pica_comic/tools/translations.dart";

class CategoryComicsPage extends StatefulWidget {
  const CategoryComicsPage({
    required this.category,
    this.param,
    required this.categoryKey,
    super.key,
  });

  final String category;

  final String? param;

  final String categoryKey;

  @override
  State<CategoryComicsPage> createState() => _CategoryComicsPageState();
}

class _CategoryComicsPageState extends State<CategoryComicsPage> {
  late final CategoryComicsData data;

  CategoryData? categoryData;

  late final List<CategoryComicsOptions> options;

  late List<String> optionsValue;

  /// 多维度筛选: 其它分组(除进入时那一组)的当前选中参数, 分组标题 -> param
  final Map<String, String?> groupValues = {};

  /// 允许在列表页平铺的分组标签数上限。
  /// 题材组有 52 个标签, 平铺会占满整屏, 所以只平铺读者群/地域这类小组。
  static const int maxInlineTags = 16;

  void findData() {
    for (final source in ComicSource.sources) {
      if (source.categoryData?.key == widget.categoryKey) {
        data = source.categoryComicsData!;
        categoryData = source.categoryData;
        options = data.options.where((element) {
          if (element.notShowWhen.contains(widget.category)) {
            return false;
          } else if (element.showWhen != null) {
            return element.showWhen!.contains(widget.category);
          }
          return true;
        }).toList();
        optionsValue = options.map((e) => e.options.keys.first).toList();
        /// 源实现了 loadMulti 才做多维度: 把其它小组的默认值(第一个标签, 通常是
        /// 「全部」)收集起来, 用户在列表页可以随时改
        if (data.loadMulti != null) {
          for (final part in categoryData!.categories) {
            final params = part.categoryParams;
            if (part.title == widget.category) continue;
            if (params == null || params.isEmpty) continue;
            if (part.categories.length > maxInlineTags) continue;
            groupValues[part.title] = params.first;
          }
        }
        return;
      }
    }
    throw "${widget.categoryKey} Not found";
  }

  @override
  void initState() {
    findData();
    _initAnchor();
    super.initState();
  }

  /// 多维度筛选: 把所有分组的当前选中值打包交给 loadMulti;
  /// 源没实现 loadMulti 时退回原来的单参数 loader
  CategoryComicsLoader get loader {
    final multi = data.loadMulti;
    if (multi == null) return data.load;
    return (category, param, options, page) {
      final params = <String, String?>{};
      if (param != null && param.isNotEmpty) {
        params[widget.category] = param;
      }
      params.addAll(groupValues);
      return multi(params, options, page);
    };
  }

  String get signature =>
      groupValues.entries.map((e) => "${e.key}=${e.value}").join("&");

  // ==== 浏览位置: 记录上次看到第几页, 重进时提示是否跳回 ====

  /// 本次进入页面时读到的锚点, 只在进入时读一次
  BrowseAnchor? anchor;

  /// 读到的锚点属于哪个筛选组合; 用户切了筛选就不再提示
  String? _anchorLoadedKey;

  /// 进入时的记录页: 没越过它就不覆盖记录, 否则一进页面(只加载第 1 页)
  /// 就会把「上次看到第 5 页」冲成第 1 页
  int _anchorFloor = 0;

  /// 用户点了「从头看」
  bool anchorDismissed = false;

  bool anchorJumping = false;

  String? anchorProgress;

  AnchorDiff? anchorDiff;

  int? anchorJumpPage;

  /// 正在拉「新增」条目(旧到新排序下点按钮时才拉)
  bool anchorFetchingNew = false;

  String get _sortValue => optionsValue.isEmpty ? "" : optionsValue.first;

  String get _anchorSourceKey {
    for (final source in ComicSource.sources) {
      if (source.categoryData?.key == widget.categoryKey) return source.key;
    }
    return "";
  }

  /// 与 _CategoryComicsList.tag 一致, 用来找到当前的 ComicsPageLogic
  String get _listTag =>
      "${widget.category} with ${widget.param} and $optionsValue and $signature";

  /// 一个筛选组合(源|分类|子分类|排序|多维度)对应一条存储记录
  String get _anchorKey =>
      "$_anchorSourceKey|${widget.category}|${widget.param}|${optionsValue.join(",")}|$signature";

  /// 只对哔咔的非「新到旧」排序启用; 新到旧下新作品插在最前, 页号会整体漂移。
  /// 「最新」「随机」这类没有排序选项的分类(排序值为空)不参与记录
  bool get _anchorEnabled =>
      _anchorSourceKey == "picacg" &&
      _sortValue.isNotEmpty &&
      _sortValue != "dd";

  /// 当前列表的取页函数(把源 loader 收成单页参数)
  Future<Res<List<BaseComic>>> Function(int) get _pageLoader =>
      (page) => loader(widget.category, widget.param, optionsValue, page);

  void _initAnchor() {
    if (!_anchorEnabled) return;
    _anchorLoadedKey = _anchorKey;
    anchor = BrowseAnchorStore.instance[_anchorKey];
    _anchorFloor = anchor?.page ?? 0;
  }

  List<BaseComic> _loadedComics(ComicsPageLogic<BaseComic> logic) {
    if (appdata.settings[25] == "0") return logic.comics ?? const [];
    return logic.dividedComics?[logic.current] ?? const [];
  }

  /// 把当前浏览位置写进本机存储; 列表每次状态变化都会走这里, 内容没变时内部直接返回
  void _recordAnchor(ComicsPageLogic<BaseComic> logic) {
    if (!_anchorEnabled) return;
    if (logic.current <= _anchorFloor) return;
    var loaded = _loadedComics(logic);
    if (loaded.isEmpty || logic.current < 1) return;
    var items = <String, int>{};
    for (final comic in loaded) {
      items[comic.id] = comicPageCount(comic) ?? -1;
    }
    BrowseAnchorStore.instance.record(
      _anchorKey,
      page: logic.current,
      lastId: loaded.last.id,
      totalPages: logic.maxPage ?? 0,
      items: items,
    );
  }

  Future<void> _jumpToAnchor() async {
    var old = anchor;
    if (old == null || anchorJumping) return;
    var logic =
        StateController.findOrNull<ComicsPageLogic<BaseComic>>(tag: _listTag);
    if (logic == null) return;
    setState(() {
      anchorJumping = true;
      anchorProgress = null;
      anchorDiff = null;
    });
    bool ok;
    if (appdata.settings[25] == "0") {
      // 顺序模式是累加列表, 只能一页页补到目标页
      ok = await logic.loadTo(_pageLoader, old.page,
          onProgress: (loaded, target) {
        if (mounted) {
          setState(() => anchorProgress = "$loaded/$target");
        }
      });
    } else {
      ok = await logic.jumpTo(_pageLoader, old.page);
    }
    if (!mounted) return;
    var diff = computeAnchorDiff(
      old: old,
      loaded: _loadedComics(logic),
      totalPages: logic.maxPage,
      stableOrder: _sortValue == "da",
    );
    setState(() {
      anchorJumping = false;
      anchorProgress = null;
      anchorJumpPage = logic.current;
      anchorDiff = ok ? diff : null;
      // 已经跳到(或尝试跳到)目标页, 之后的浏览照常记录
      _anchorFloor = 0;
    });
    if (!ok) {
      showToast(message: "部分页加载失败, 浏览位置可能不完整".tl);
    }
  }

  /// 看看新增了啥: 排序会漂移的列表直接在内存里筛, 旧到新排序才去拉
  Future<void> _showNewComics() async {
    var old = anchor;
    if (old == null || anchorFetchingNew) return;
    List<BaseComic> items;
    var restPages = 0;
    if (_sortValue == "da") {
      var logic =
          StateController.findOrNull<ComicsPageLogic<BaseComic>>(tag: _listTag);
      var basePage = old.totalPages > 0 ? old.totalPages : (logic?.current ?? 1);
      var total = logic?.maxPage ?? basePage;
      setState(() => anchorFetchingNew = true);
      var fetched = <BaseComic>[];
      var pages = 0;
      // 最多补 3 页, 隔太久没来的情况不可能全拉
      for (var page = basePage + 1;
          page <= total && pages < 3 && mounted;
          page++) {
        var res = await _pageLoader(page);
        if (res.error || res.data.isEmpty) break;
        fetched.addAll(res.data);
        pages++;
      }
      if (!mounted) return;
      setState(() => anchorFetchingNew = false);
      items = fetched;
      restPages = total - (basePage + pages);
      if (restPages < 0) restPages = 0;
    } else {
      items = anchorDiff?.newComics ?? const [];
    }
    if (!mounted) return;
    if (items.isEmpty) {
      showToast(message: "没有拉到新增内容".tl);
      return;
    }
    _openNewComicsSheet(items, restPages);
  }

  void _openNewComicsSheet(List<BaseComic> items, int restPages) {
    var theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, controller) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                "上次之后新增的 ${items.length} 部".tl,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                restPages > 0
                    ? "还有 $restPages 页没拉, 想看更多就继续往下翻".tl
                    : "点封面可以看详情".tl,
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.outline),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: GridView.builder(
                controller: controller,
                padding: const EdgeInsets.all(8),
                gridDelegate: SliverGridDelegateWithComics(),
                itemCount: items.length,
                itemBuilder: (context, i) =>
                    buildComicTile(context, items[i], _anchorSourceKey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 是否展示「上次看到第几页」提示条; 切换筛选/子分类后不提示(记录照旧)
  bool get _showAnchorBanner =>
      _anchorEnabled &&
      anchor != null &&
      !anchorDismissed &&
      _anchorLoadedKey == _anchorKey;

  Widget buildAnchorBanner() {
    var old = anchor;
    if (old == null || !_showAnchorBanner) return const SizedBox.shrink();
    var theme = Theme.of(context);
    var diff = anchorDiff;
    var done = anchorJumpPage != null;
    String title;
    String? subtitle;
    if (anchorJumping) {
      title = "正在补齐到第 ${old.page} 页".tl;
      if (anchorProgress != null) {
        subtitle = "已加载 $anchorProgress 页".tl;
      }
    } else if (done) {
      title = "已跳到第 $anchorJumpPage 页".tl;
      if (diff == null) {
        subtitle = "部分页加载失败, 位置可能不完整".tl;
      } else if (diff.isEmpty) {
        subtitle = "没有发现新内容".tl;
      } else {
        var text = diff.fromPageDiff
            ? "此后新增约 ${diff.addedCount} 部(${diff.addedPages} 页)"
            : "这一片里新出现 ${diff.addedCount} 部";
        if (diff.updatedCount > 0) {
          text = "$text, 你看过的 ${diff.updatedCount} 部有更新";
        }
        subtitle = text.tl;
      }
    } else {
      title = "上次看到第 ${old.page} 页".tl;
      if (old.totalPages > 0) {
        subtitle = "站点当时共 ${old.totalPages} 页".tl;
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.history, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                if (subtitle != null)
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.outline)),
              ],
            ),
          ),
          if (!done)
            TextButton(
              onPressed: anchorJumping ? null : _jumpToAnchor,
              child: Text("跳到第 ${old.page} 页".tl),
            )
          else if (diff != null && !diff.isEmpty)
            TextButton(
              onPressed: anchorFetchingNew ? null : _showNewComics,
              child: Text(anchorFetchingNew ? "拉取中".tl : "看看新增了啥".tl),
            ),
          TextButton(
            onPressed: () => setState(() {
              anchorDismissed = true;
              _anchorFloor = 0;
            }),
            child: Text(done ? "知道了".tl : "从头看".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text(widget.category),
      ),
      body: Column(
        children: [
          Expanded(
            child: _CategoryComicsList(
              key: ValueKey(
                  "${widget.category} with ${widget.param} and $optionsValue and $signature"),
              loader: loader,
              signature: signature,
              category: widget.category,
              options: optionsValue,
              param: widget.param,
              header: buildOptions(
                  extra: [if (_showAnchorBanner) buildAnchorBanner()]),
              onLogicUpdate: _recordAnchor,
              sourceKey: ComicSource.sources
                  .firstWhere((e) => e.categoryData?.key == widget.categoryKey)
                  .key,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildOptionItem(
      String text, String value, int group, BuildContext context) {
    return OptionChip(
      text: text,
      isSelected: value == optionsValue[group],
      onTap: () {
        if (value == optionsValue[group]) return;
        setState(() {
          optionsValue[group] = value;
        });
      },
    );
  }

  Widget _buildGroupTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: Text(title.tl,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
    );
  }

  BaseCategoryPart? _findPart(String title) {
    for (final candidate in categoryData!.categories) {
      if (candidate.title == title) return candidate;
    }
    return null;
  }

  /// 其它分组(读者群/地域等小组)平铺成可选标签
  List<Widget> buildGroupChips() {
    final children = <Widget>[];
    for (final entry in groupValues.entries) {
      final part = _findPart(entry.key);
      final params = part?.categoryParams;
      final tags = part?.categories;
      if (params == null || tags == null) continue;
      children.add(_buildGroupTitle(entry.key));
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < tags.length; i++)
            OptionChip(
              text: tags[i].tl,
              isSelected: (i < params.length ? params[i] : null) == entry.value,
              onTap: () {
                final value = i < params.length ? params[i] : null;
                if (value == groupValues[entry.key]) return;
                setState(() {
                  groupValues[entry.key] = value;
                });
              },
            )
        ],
      ));
      children.add(const SizedBox(height: 8));
    }
    return children;
  }

  Widget buildOptions({List<Widget> extra = const []}) {
    List<Widget> children = [];
    children.addAll(buildGroupChips());
    for (var optionList in options) {
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var option in optionList.options.entries)
            buildOptionItem(
              option.value.tl,
              option.key,
              options.indexOf(optionList),
              context,
            )
        ],
      ));
      if (options.last != optionList) {
        children.add(const SizedBox(height: 8));
      }
    }
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...children,
          ...extra,
          if (extra.isNotEmpty) const SizedBox(height: 8),
          const Divider(),
        ],
      ).paddingLeft(8).paddingRight(8),
    );
  }
}

class _CategoryComicsList extends ComicsPage<BaseComic> {
  const _CategoryComicsList({
    super.key,
    required this.loader,
    required this.category,
    required this.options,
    this.param,
    required this.header,
    required this.sourceKey,
    required this.signature,
    this.onLogicUpdate,
  });

  final CategoryComicsLoader loader;

  final String category;

  final List<String> options;

  final String? param;

  /// 多维度筛选项的签名, 用来区分同一分组下不同的筛选组合(状态缓存与 key)
  final String signature;

  /// 列表每次重建时把 logic 交给页面, 用于记录浏览位置
  @override
  final void Function(ComicsPageLogic<BaseComic> logic)? onLogicUpdate;

  @override
  final String sourceKey;

  @override
  final Widget header;

  @override
  Future<Res<List<BaseComic>>> getComics(int i) async {
    return await loader(category, param, options, i);
  }

  @override
  String? get tag => "$category with $param and $options and $signature";

  @override
  String? get title => null;
}
