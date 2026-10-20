import "package:flutter/material.dart";
import "package:pica_comic/comic_source/comic_source.dart";
import 'package:pica_comic/components/components.dart';
import "package:pica_comic/foundation/app.dart";
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
              header: buildOptions(),
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

  Widget buildOptions() {
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
        children: [...children, const Divider()],
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
  });

  final CategoryComicsLoader loader;

  final String category;

  final List<String> options;

  final String? param;

  /// 多维度筛选项的签名, 用来区分同一分组下不同的筛选组合(状态缓存与 key)
  final String signature;

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
