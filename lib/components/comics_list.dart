part of 'components.dart';

class ComicsPageLogic<T> extends StateController {
  bool loading = true;

  ///用于正常模式下的漫画数据储存
  List<T>? comics;

  ///用于分页模式下的漫画数据储存
  Map<int, List<T>>? dividedComics;

  ///错误信息, null表示没有错误
  String? message;

  /// 最大页数, 为null表示不知道或者无穷
  int? maxPage;

  ///当前的页面序号
  int current = 1;

  ///是否正在获取数据， 用于在顺序浏览模式下， 避免同时进行多个网络请求
  bool loadingData = false;

  bool showFloatingButton = true;

  /// 是否处于多选模式
  bool selecting = false;

  /// 多选模式下已选中的漫画 id
  final Set<String> selectedIds = {};

  void enterSelectionMode() {
    selecting = true;
    selectedIds.clear();
    update();
  }

  void exitSelectionMode() {
    selecting = false;
    selectedIds.clear();
    update();
  }

  void toggleSelect(String id) {
    if (!selectedIds.remove(id)) {
      selectedIds.add(id);
    }
    update();
  }

  void selectAll(Iterable<String> ids) {
    selectedIds
      ..clear()
      ..addAll(ids);
    update();
  }

  void clearSelection() {
    selectedIds.clear();
    update();
  }

  void get(Future<Res<List<T>>> Function(int) getComics) async {
    if (loadingData) return;
    loadingData = true;
    Future.microtask(() => update());
    if (comics == null) {
      var res = await getComics(1);
      if (res.error) {
        message = res.errorMessage;
      } else {
        comics = res.data;
        dividedComics = {};
        dividedComics![1] = res.data;
        if (res.subData is int) {
          maxPage = res.subData;
        }
        if (res.data.isEmpty) {
          maxPage = 1;
        }
      }
      loading = false;
      loadingData = false;
      update();
    } else {
      var res = await getComics(current);
      if (res.error) {
        message = res.errorMessage;
      } else {
        dividedComics![current] = res.data;
      }
      loading = false;
      loadingData = false;
      update();
    }
  }

  int _emptyPageCount = 0;

  void loadNextPage(Future<Res<List<T>>> Function(int) getComics) async {
    if (maxPage != null && current >= maxPage!) return;
    if (loadingData) return;
    loadingData = true;
    Future.microtask(() => update());
    var res = await getComics(current + 1);
    if (res.error) {
      showToast(message: res.errorMessage!);
    } else {
      if (res.subData is int) {
        maxPage = res.subData;
      }
      if (res.data.isEmpty) {
        _emptyPageCount++;
        if (_emptyPageCount > 3 && maxPage == null) {
          // 某些漫画源不会返回总页数, 而app的网络代码会根据用户设置进行屏蔽操作
          // 空页面既可能是因为没有更多页面, 也可能是因为被屏蔽了
          // 如果连续3次加载空页面, 则认为已经加载完毕
          maxPage = current;
        }
        // 等待一会儿再加载, 避免因为某些错误导致无限加载
        await Future.delayed(const Duration(seconds: 1));
      } else {
        _emptyPageCount = 0;
        comics!.addAll(res.data);
      }
    }
    current++;
    loadingData = false;
    update();
  }

  @override
  void refresh() {
    loading = true;
    comics = null;
    message = null;
    update();
  }
}

/// 漫画列表页面
///
/// T为漫画信息模型
abstract class ComicsPage<T extends BaseComic> extends StatelessWidget {
  const ComicsPage({super.key});

  ///标题
  String? get title;

  /// 是否居中标题
  bool get centerTitle => true;

  /// 获取图片, 参数为页面序号, **从1开始**
  ///
  /// 返回值Res的subData为页面总数
  Future<Res<List<T>>> getComics(int i);

  /// 漫画源标识符
  String get sourceKey;

  /// 显示一个刷新按钮, 需要Scaffold启用
  bool get withRefreshFloatingButton => false;

  String? get tag;

  Widget? get tailing => null;

  Widget? get header => null;

  bool get showPageIndicator => true;

  List<ComicTileMenuOption>? get addonMenuOptions => null;

  /// 刷新页面
  void refresh() {
    StateController.find<ComicsPageLogic<T>>(tag: tag).refresh();
  }

  @override
  Widget build(context) {
    Widget? removeSliver(Widget? widget) {
      if (widget == null) return null;

      if (widget is SliverToBoxAdapter) {
        return widget.child;
      }

      if (widget is SliverPersistentHeader) {
        return SizedBox(
          height: widget.delegate.minExtent,
          child: widget.delegate.build(
            context,
            widget.delegate.minExtent,
            false,
          ),
        );
      }

      return widget;
    }

    Widget body = StateBuilder<ComicsPageLogic<T>>(
        init: ComicsPageLogic<T>(),
        tag: tag,
        builder: (logic) {
          if (logic.dividedComics?[logic.current] == null &&
              logic.message == null &&
              appdata.settings[25] != "0") {
            logic.loading = true;
          }
          if (logic.loading) {
            logic.get(getComics);
            return Column(
              children: [
                if (title != null) const Appbar(title: Text("")),
                removeSliver(header) ?? const SizedBox(),
                const Expanded(
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                )
              ],
            );
          } else if (logic.message != null) {
            return Column(
              children: [
                removeSliver(header) ?? const SizedBox(),
                Expanded(
                    child: NetworkError(
                  message: logic.message ?? "Network Error",
                  retry: logic.refresh,
                  withAppbar: title != null,
                ))
              ],
            );
          } else {
            if (appdata.settings[25] == "0") {
              List<T> comics = [];
              if (appdata.appSettings.fullyHideBlockedWorks) {
                for (var comic in logic.comics!) {
                  if (isBlocked(comic) == null) {
                    comics.add(comic);
                  }
                }
              } else {
                comics = logic.comics!;
              }
              if (comics.isEmpty) {
                return SmoothCustomScrollView(
                  slivers: [
                    if (title != null)
                      SliverAppbar(
                        title: Text(title!),
                        actions: tailing != null ? [tailing!] : null,
                      ),
                    if (header != null) header!,
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: buildEmptyView(context),
                    ),
                  ],
                );
              }
              var content = SmoothCustomScrollView(
                slivers: [
                  if (title != null)
                    SliverAppbar(
                      title: Text(title!),
                      actions: tailing != null ? [tailing!] : null,
                    ),
                  if (header != null) header!,
                  SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                        childCount: comics.length, (context, i) {
                      if (i == comics.length - 1) {
                        logic.loadNextPage(getComics);
                      }
                      return buildItem(context, comics[i]);
                    }),
                    gridDelegate: SliverGridDelegateWithComics(),
                  ),
                  if (logic.current < (logic.maxPage ?? 114514) &&
                      logic.loadingData)
                    const SliverToBoxAdapter(
                      child: ListLoadingIndicator(),
                    )
                  else
                    const SliverToBoxAdapter(
                      child: SizedBox(
                        height: 80,
                      ),
                    )
                ],
              );
              return buildSelectableBody(context, logic, comics, content);
            } else {
              List<T> comics = [];
              if (appdata.appSettings.fullyHideBlockedWorks) {
                for (var comic in logic.dividedComics![logic.current]!) {
                  if (isBlocked(comic) == null) {
                    comics.add(comic);
                  }
                }
              } else {
                comics = logic.dividedComics![logic.current]!;
              }
              if (comics.isEmpty) {
                return SmoothCustomScrollView(
                  slivers: [
                    if (title != null)
                      SliverAppbar(
                        title: Text(title!),
                        actions: tailing != null ? [tailing!] : null,
                      ),
                    if (header != null) header!,
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: buildEmptyView(context),
                    ),
                  ],
                );
              }
              Widget body = SmoothCustomScrollView(
                slivers: [
                  if (title != null)
                    SliverAppbar(
                      title: Text(title!),
                      actions: tailing != null ? [tailing!] : null,
                    ),
                  if (header != null) header!,
                  if (showPageIndicator &&
                      appdata.settings[64] == "0" &&
                      logic.maxPage != 1)
                    buildPageSelector(context, logic),
                  SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                        childCount: comics.length, (context, i) {
                      return buildItem(context, comics[i]);
                    }),
                    gridDelegate: SliverGridDelegateWithComics(),
                  ),
                  if (showPageIndicator &&
                      appdata.settings[64] == "0" &&
                      logic.maxPage != 1)
                    buildPageSelector(context, logic),
                  SliverPadding(
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.of(context).padding.bottom))
                ],
              );

              body = NotificationListener<ScrollUpdateNotification>(
                onNotification: (notifications) {
                  if (notifications.scrollDelta != null) {
                    if (notifications.scrollDelta! > 0 &&
                        logic.showFloatingButton) {
                      logic.showFloatingButton = false;
                      logic.update();
                    } else if ((notifications.scrollDelta! < 0 ||
                            notifications.metrics.pixels ==
                                notifications.metrics.minScrollExtent ||
                            notifications.metrics.pixels ==
                                notifications.metrics.maxScrollExtent) &&
                        !logic.showFloatingButton) {
                      logic.showFloatingButton = true;
                      logic.update();
                    }
                  }
                  return false;
                },
                child: body,
              );

              body = buildSelectableBody(context, logic, comics, body);

              if (showPageIndicator && appdata.settings[64] == "1") {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: body,
                    ),
                    Positioned(
                      left: 0,
                      right: 12,
                      top: 0,
                      bottom: 0,
                      child: buildPageSelectorRight(context, logic),
                    )
                  ],
                );
              } else {
                return body;
              }
            }
          }
        });

    if (header != null && UiMode.m1(context)) {
      body = SafeArea(
        bottom: false,
        child: body,
      );
    }

    if (withRefreshFloatingButton) {
      return Scaffold(
        floatingActionButton: FloatingActionButton(
          child: const Icon(Icons.refresh),
          onPressed: () {
            refresh();
          },
        ),
        body: body,
      );
    } else {
      return Material(
        child: body,
      );
    }
  }

  Widget buildPageSelector(BuildContext context, ComicsPageLogic logic) {
    return SliverToBoxAdapter(
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 8),
          child: SizedBox(
            width: 300,
            height: 42,
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                ),
                FilledButton.tonal(
                    onPressed: () => prevPage(logic), child: Text("上一页".tl)),
                const Spacer(),
                ActionChip(
                  label: Text(
                      "${"页面".tl}: ${logic.current}/${logic.maxPage?.toString() ?? "?"}"),
                  onPressed: () async {
                    selectPage(logic);
                  },
                  elevation: 1,
                  side: BorderSide.none,
                ),
                const Spacer(),
                FilledButton.tonal(
                    onPressed: () => nextPage(logic), child: Text("下一页".tl)),
                const SizedBox(
                  width: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildPageSelectorRight(BuildContext context, ComicsPageLogic logic) {
    return Align(
        alignment: Alignment.centerRight,
        child: AnimatedSlide(
          offset: logic.showFloatingButton
              ? const Offset(0, 0)
              : const Offset(1.5, 0),
          duration: const Duration(milliseconds: 200),
          child: Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(16),
            elevation: 3,
            child: SizedBox(
              height: 156,
              width: 58,
              child: Column(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16)),
                      onTap: () {
                        prevPage(logic);
                      },
                      child: const SizedBox.expand(
                        child: Center(
                          child: Icon(Icons.keyboard_arrow_left),
                        ),
                      ),
                    ),
                  ),
                  const Divider(
                    height: 1,
                  ),
                  Expanded(
                      child: InkWell(
                    onTap: () {
                      selectPage(logic);
                    },
                    child: SizedBox.expand(
                      child: Center(
                        child: Text(
                            "${logic.current}/${logic.maxPage?.toString() ?? "?"}"),
                      ),
                    ),
                  )),
                  const Divider(
                    height: 1,
                  ),
                  Expanded(
                    child: InkWell(
                      borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16)),
                      onTap: () {
                        nextPage(logic);
                      },
                      child: const SizedBox.expand(
                        child: Center(
                          child: Icon(Icons.keyboard_arrow_right),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
  }

  void nextPage(ComicsPageLogic logic) {
    if (logic.current == logic.maxPage || logic.current == 0) {
      showToast(message: "已经是最后一页了".tl);
    } else {
      logic.current++;
      logic.update();
    }
  }

  void prevPage(ComicsPageLogic logic) {
    if (logic.current == 1 || logic.current == 0) {
      showToast(message: "已经是第一页了".tl);
    } else {
      logic.current--;
      logic.update();
    }
  }

  void selectPage(ComicsPageLogic logic) async {
    String res = "";
    await showDialog(
        context: App.globalContext!,
        builder: (dialogContext) {
          var controller = TextEditingController();
          return SimpleDialog(
            title: const Text("切换页面"),
            children: [
              const SizedBox(
                width: 300,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                child: TextField(
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: "页码".tl,
                    suffixText:
                        "${"输入范围: ".tl}1-${logic.maxPage?.toString() ?? "?"}",
                  ),
                  controller: controller,
                  onSubmitted: (s) {
                    res = s;
                    App.globalBack();
                  },
                ),
              ),
              Center(
                child: FilledButton(
                  child: Text("提交".tl),
                  onPressed: () {
                    res = controller.text;
                    App.globalBack();
                  },
                ),
              )
            ],
          );
        });
    if (res.isNum) {
      int i = int.parse(res);
      if (logic.maxPage == null || (i > 0 && i <= logic.maxPage!)) {
        logic.current = i;
        logic.update();
        return;
      }
    }
    if (res != "") {
      showToast(message: "输入的数字不正确".tl);
    }
  }

  Widget buildEmptyView(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 56),
          const SizedBox(height: 12),
          Text("无匹配结果".tl,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget buildItem(BuildContext context, T item) {
    var tile = buildComicTile(context, item, sourceKey,
        addonMenuOptions: addonMenuOptions);
    var logic = StateController.findOrNull<ComicsPageLogic<T>>(tag: tag);
    if (logic == null || !logic.selecting) {
      return tile;
    }
    var selected = logic.selectedIds.contains(item.id);
    var primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: () => logic.toggleSelect(item.id),
      child: Stack(
        children: [
          IgnorePointer(child: tile),
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color: selected ? primary.withOpacity(0.3) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: selected ? Border.all(color: primary, width: 2) : null,
              ),
              child: selected
                  ? Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.check_circle, color: primary),
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  /// 多选模式下的顶部操作栏
  Widget buildSelectionBar(
      BuildContext context, ComicsPageLogic logic, List<T> comics) {
    var allSelected =
        comics.isNotEmpty && logic.selectedIds.length >= comics.length;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(
          children: [
            Text("@a 已选".tlParams({"a": "${logic.selectedIds.length}"})),
            const Spacer(),
            TextButton(
              onPressed: () {
                if (allSelected) {
                  logic.clearSelection();
                } else {
                  logic.selectAll(comics.map((e) => e.id));
                }
              },
              child: Text(allSelected ? "取消全选".tl : "全选本页".tl),
            ),
            const SizedBox(
              width: 4,
            ),
            FilledButton(
              onPressed: () {
                var requests = <({String key, String target, String title})>[];
                for (var comic in comics) {
                  if (logic.selectedIds.contains(comic.id)) {
                    requests.add(
                        (key: sourceKey, target: comic.id, title: comic.title));
                  }
                }
                if (requests.isEmpty) {
                  showToast(message: "请先选择漫画".tl);
                  return;
                }
                // 确认下载后由回调退出多选(清空选择并收起横幅);
                // 在确认框点取消则保留选择, 可继续调整
                downloadComicsDirectly(requests,
                    onConfirmed: logic.exitSelectionMode);
              },
              child: Text("下载".tl),
            ),
            const SizedBox(
              width: 4,
            ),
            TextButton(
              onPressed: () => logic.exitSelectionMode(),
              child: Text("取消".tl),
            ),
          ],
        ),
      ),
    );
  }

  /// 多选模式下在列表上方插入操作栏
  Widget buildSelectableBody(BuildContext context, ComicsPageLogic logic,
      List<T> comics, Widget child) {
    if (!logic.selecting) {
      return child;
    }
    return Column(
      children: [
        buildSelectionBar(context, logic, comics),
        Expanded(child: child),
      ],
    );
  }
}

class SliverGridComicsController extends StateController {}

class SliverGridComics extends StatelessWidget {
  const SliverGridComics({
    super.key,
    required this.comics,
    required this.sourceKey,
    this.onLastItemBuild,
  });

  final List<BaseComic> comics;

  final String sourceKey;

  final void Function()? onLastItemBuild;

  @override
  Widget build(BuildContext context) {
    return StateBuilder<SliverGridComicsController>(
      init: SliverGridComicsController(),
      builder: (controller) {
        List<BaseComic> comics = [];
        if (appdata.appSettings.fullyHideBlockedWorks) {
          for (var comic in this.comics) {
            if (isBlocked(comic) == null) {
              comics.add(comic);
            }
          }
        } else {
          comics = this.comics;
        }
        return _SliverGridComics(
          comics: comics,
          sourceKey: sourceKey,
          onLastItemBuild: onLastItemBuild,
        );
      },
    );
  }
}

class _SliverGridComics extends StatelessWidget {
  const _SliverGridComics({
    required this.comics,
    required this.sourceKey,
    this.onLastItemBuild,
  });

  final List<BaseComic> comics;

  final String sourceKey;

  final void Function()? onLastItemBuild;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate(
            (context, index) {
          if (index == comics.length - 1) {
            onLastItemBuild?.call();
          }
          return buildComicTile(context, comics[index], sourceKey);
        },
        childCount: comics.length,
      ),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }
}