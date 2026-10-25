part of 'components.dart';

// 构建触发探针: 无功能影响, 可随下次改动一并删除

/// 没有章节概念的内置源：一本即全部内容。
const _wholeComicSources = {'ehentai', 'hitomi', 'htmanga', 'nhentai'};

/// 单本漫画加入下载队列的结果, 用于批量下载时逐条展示。
enum DownloadEnqueueResult {
  /// 已加入下载队列
  queued,

  /// 已下载过、已在队列中、或用户取消
  skipped,

  /// 拉取信息失败, 或该源不支持
  failed,
}

/// 单本漫画的处理结果 + 展示用的信息。
class DownloadEnqueueOutcome {
  const DownloadEnqueueOutcome(
    this.result, {
    this.epCount,
    this.pageCount,
    this.epIds,
    this.message,
  });

  final DownloadEnqueueResult result;

  /// 话数(整本源恒为 1)
  final int? epCount;

  /// 总页数; 源未提供时为 null(例如禁漫)
  final int? pageCount;

  /// 逐话标识, 供展开时按需查询每话页数; 整本源为 null
  final List<String>? epIds;

  /// 失败原因
  final String? message;

  String get summary {
    var parts = <String>[];
    if (epCount != null) {
      parts.add(epCount! <= 1 ? "1话".tl : "@c话".tlParams({"c": "$epCount"}));
    }
    if (pageCount != null) {
      parts.add("@cP".tlParams({"c": "$pageCount"}));
    }
    return parts.join(" · ");
  }
}

/// 下载标识规则, 与 [FavoriteItem.toDownloadId] 保持一致。
String _downloadIdOf(String sourceKey, String target) {
  switch (sourceKey) {
    case 'picacg':
      return target;
    case 'ehentai':
      return getGalleryId(target);
    case 'jm':
      return "jm$target";
    case 'hitomi':
      return RegExp(r"\d+(?=\.html)").hasMatch(target)
          ? "hitomi${RegExp(r"\d+(?=\.html)").firstMatch(target)?[0]}"
          : target;
    case 'htmanga':
      return "Ht$target";
    case 'nhentai':
      return "nhentai$target";
    default:
      return DownloadManager().generateId(sourceKey, target);
  }
}

/// 是否已有同 id 的任务在队列里。
bool _isInDownloadingQueue(String downloadId) {
  for (var i in DownloadManager().downloading) {
    if (i.id == downloadId) {
      return true;
    }
  }
  return false;
}

/// 取出已下载的章节序号。
Future<List<int>> _downloadedEpsOf(String downloadId) async {
  if (!DownloadManager().isExists(downloadId)) {
    return [];
  }
  var item = await DownloadManager().getComicOrNull(downloadId);
  return item?.downloadedEps.toList() ?? [];
}

/// 查询某一话的页数, 用于批量面板展开时按需加载。
///
/// [epId] 对 picacg 是章节序号, 对禁漫是 chapter id, 对自定义源是章节 id。
Future<int?> loadEpPageCount(
    String sourceKey, String target, String epId) async {
  try {
    if (sourceKey == 'picacg') {
      final res = await PicacgNetwork()
          .getComicContent(target, int.tryParse(epId) ?? 0);
      return res.error ? null : res.data.length;
    }
    if (sourceKey == 'jm') {
      final res = await JmNetwork().getChapter(epId);
      return res.error ? null : res.data.length;
    }
    final source = ComicSource.find(sourceKey);
    if (source == null || source.loadComicPages == null) {
      return null;
    }
    final res = await source.loadComicPages!(target, epId);
    return res.error ? null : res.data.length;
  } catch (_) {
    return null;
  }
}

/// 确认框。[count] 为 null 表示单本下载。
Future<bool> _confirmDownload(String title, {int? count}) async {
  var confirmed = false;
  await showDialog(
    context: App.globalContext!,
    builder: (context) => AlertDialog(
      title: Text(count == null ? "下载漫画".tl : "批量下载".tl),
      content: Text(
        count == null
            ? title.replaceAll("\n", "")
            : "@c 部漫画的全部未下载内容".tlParams({"c": "$count"}),
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text("取消".tl),
        ),
        FilledButton(
          onPressed: () {
            confirmed = true;
            context.pop();
          },
          child: Text("下载".tl),
        ),
      ],
    ),
  );
  return confirmed;
}

/// 弹出已有的章节选择框, 已下载章节不可选, “下载全部”只补缺。
void _showChapterSelector(List<String> eps, List<int> downloaded,
    void Function(List<int> selected) onConfirm) {
  var content = SelectDownloadChapter(
    eps,
    (selectedEps) {
      onConfirm(selectedEps);
      App.globalBack();
      showToast(message: "已加入下载队列".tl);
    },
    downloaded,
  );
  if (UiMode.m1(App.globalContext!)) {
    showModalBottomSheet(
      context: App.globalContext!,
      builder: (context) => content,
    );
  } else {
    showSideBar(App.globalContext!, content, useSurfaceTintColor: true);
  }
}

/// 只补缺: 全部章节里排除已下载的。
List<int> _missingEps(List<String> eps, List<int> downloaded) {
  var res = <int>[];
  for (int i = 0; i < eps.length; i++) {
    if (!downloaded.contains(i)) {
      res.add(i);
    }
  }
  return res;
}

/// 从漫画列表项直接发起下载。
///
/// [sourceKey] 漫画源 key; [target] 传给源接口的标识(多数源是漫画 id,
/// e-hentai 与 hitomi 是链接); [title] 仅用于确认提示。
/// [selectChapter] 为 false 时(批量下载)不弹章节框, 直接补下缺失章节。
/// [silent] 为 true 时不弹任何单本对话框、也不发提示, 由调用方统一展示进度。
Future<DownloadEnqueueOutcome> downloadComicDirectly({
  required String sourceKey,
  required String target,
  required String title,
  bool selectChapter = true,
  bool silent = false,
}) async {
  final downloadId = _downloadIdOf(sourceKey, target);
  if (_isInDownloadingQueue(downloadId)) {
    if (!silent) {
      showToast(message: "下载中".tl);
    }
    return const DownloadEnqueueOutcome(DownloadEnqueueResult.skipped,
        message: "已在下载队列中");
  }

  if (sourceKey == 'picacg') {
    return _downloadPicacg(target, downloadId, selectChapter, silent);
  } else if (sourceKey == 'jm') {
    return _downloadJm(target, downloadId, selectChapter, silent);
  } else if (_wholeComicSources.contains(sourceKey)) {
    return _downloadWholeComic(sourceKey, target, title, downloadId, silent);
  } else {
    return _downloadCustomSource(
        sourceKey, target, downloadId, selectChapter, silent);
  }
}

/// 批量下载: 确认一次后, 用进度面板逐本入队。
///
/// 面板列出每一本漫画及其状态与话数/页数, 每本可展开查看逐话页数
/// (展开时才请求)。处理过程中可中断, 剩余的不再入队。
Future<void> downloadComicsDirectly(
    List<({String key, String target, String title})> requests,
  {void Function()? onConfirmed}) async {
  if (requests.isEmpty) {
    showToast(message: "所选漫画不支持直接下载".tl);
    return;
  }
  if (!await _confirmDownload("", count: requests.length)) {
    return;
  }
  // 确认通过才通知调用方(如退出多选); 用户取消则完全不动
  onConfirmed?.call();

  var progress = ValueNotifier<List<DownloadEnqueueOutcome?>>(
      List<DownloadEnqueueOutcome?>.filled(requests.length, null));
  var currentIndex = ValueNotifier<int>(-1);
  var running = ValueNotifier<bool>(true);
  var cancelled = false;

  /// 依次处理指定索引(首次为全量, 重试时只传失败项)
  Future<void> runIndices(List<int> indices) async {
    for (var i in indices) {
      if (cancelled) {
        break;
      }
      currentIndex.value = i;
      var outcome = await downloadComicDirectly(
        sourceKey: requests[i].key,
        target: requests[i].target,
        title: requests[i].title,
        selectChapter: false,
        silent: true,
      );
      var next = List<DownloadEnqueueOutcome?>.from(progress.value);
      next[i] = outcome;
      progress.value = next;
    }
    currentIndex.value = -1;
  }

  var panelClosed = false;
  void closePanel(BuildContext dialogContext) {
    panelClosed = true;
    if (dialogContext.mounted) {
      dialogContext.pop();
    }
  }

  showDialog(
    context: App.globalContext!,
    barrierDismissible: false,
    builder: (dialogContext) => _BatchDownloadPanel(
      requests: requests,
      progress: progress,
      currentIndex: currentIndex,
      running: running,
      onCancel: () => cancelled = true,
      onClose: () => closePanel(dialogContext),
      onRetry: (indices) async {
        // 之前若点过「中断」, cancelled 会停在 true, 这里必须复位才能继续处理
        cancelled = false;
        running.value = true;
        await runIndices(indices);
        running.value = false;
        // 重试完全部成功时同样自动收起, 有失败项则留着供再次重试
        if (!panelClosed && !cancelled) {
          var allDone = progress.value.every((e) => e != null);
          var anyFailed =
              progress.value.any((e) => e?.result == DownloadEnqueueResult.failed);
          if (allDone && !anyFailed) {
            closePanel(dialogContext);
          }
        }
      },
    ),
  );

  await runIndices(List<int>.generate(requests.length, (i) => i));
  running.value = false;
  // 全部入队且没有失败、用户也没主动操作面板时自动关闭,
  // 不再残留一个"确认完还挂着"的进度框
  if (!panelClosed && !cancelled) {
    var allDone = progress.value.every((e) => e != null);
    var anyFailed =
        progress.value.any((e) => e?.result == DownloadEnqueueResult.failed);
    if (allDone && !anyFailed) {
      // 稍等片刻让最终状态渲染出来再收起
      await Future.delayed(const Duration(milliseconds: 600));
      // 延迟期间用户可能点了中断或后台运行, 复查后再关
      if (!panelClosed && !cancelled) {
        App.globalBack();
      }
    }
  }
}

/// 查询某本漫画在下载队列中的进度; 不在队列中返回 null。
({int done, int total})? _queueProgress(String sourceKey, String target) {
  var id = _downloadIdOf(sourceKey, target);
  for (var item in DownloadManager().downloading) {
    if (item.id == id) {
      return (done: item.downloadedPages, total: item.totalPages);
    }
  }
  return null;
}

/// 批量下载进度面板: 每本一行, 可展开查看逐话页数。
class _BatchDownloadPanel extends StatefulWidget {
  const _BatchDownloadPanel({
    required this.requests,
    required this.progress,
    required this.currentIndex,
    required this.running,
    required this.onCancel,
    required this.onClose,
    required this.onRetry,
  });

  final List<({String key, String target, String title})> requests;
  final ValueNotifier<List<DownloadEnqueueOutcome?>> progress;
  final ValueNotifier<int> currentIndex;
  final ValueNotifier<bool> running;
  final void Function() onCancel;
  final void Function() onClose;
  final void Function(List<int> failedIndices) onRetry;

  @override
  State<_BatchDownloadPanel> createState() => _BatchDownloadPanelState();
}

class _BatchDownloadPanelState extends State<_BatchDownloadPanel> {
  /// 定时刷新下载进度的计时器
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 下载过程中每张图都会触发一次队列通知, 直接监听会让整个列表被高频重建;
    // 这里改成固定间隔刷新, 且队列为空时不做任何事。
    _ticker = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (!mounted) {
        return;
      }
      if (DownloadManager().downloading.isEmpty) {
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 已展开的行
  final _expanded = <int>{};

  /// 已加载的逐话页数: 行号 -> 每话页数(null 表示取不到)
  final _epPages = <int, List<int?>>{};

  /// 正在加载逐话页数的行
  final _loading = <int>{};

  Future<void> _toggleExpanded(int index) async {
    if (_expanded.contains(index)) {
      setState(() => _expanded.remove(index));
      return;
    }
    setState(() => _expanded.add(index));

    var outcome = widget.progress.value[index];
    var epIds = outcome?.epIds;
    if (epIds == null || epIds.isEmpty) {
      return;
    }
    if (_epPages.containsKey(index) || _loading.contains(index)) {
      return;
    }
    setState(() => _loading.add(index));

    var request = widget.requests[index];
    // 分批并发查询, 避免逐个往返(一本 20 话串行要几十秒);
    // 每批完成就刷新一次, 边查边显示
    var pages = List<int?>.filled(epIds.length, null);
    const batchSize = 4;
    for (var start = 0; start < epIds.length; start += batchSize) {
      var end = math.min(start + batchSize, epIds.length);
      var batch = await Future.wait([
        for (var i = start; i < end; i++)
          loadEpPageCount(request.key, request.target, epIds[i]),
      ]);
      for (var i = start; i < end; i++) {
        pages[i] = batch[i - start];
      }
      if (!mounted) {
        return;
      }
      setState(() => _epPages[index] = List<int?>.from(pages));
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _epPages[index] = pages;
      _loading.remove(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    var width = math.min(420.0, MediaQuery.of(context).size.width - 56);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("批量加入下载队列".tl, style: const TextStyle(fontSize: 19)),
          const SizedBox(height: 4),
          ValueListenableBuilder<List<DownloadEnqueueOutcome?>>(
            valueListenable: widget.progress,
            builder: (context, results, _) {
              var done = results.where((e) => e != null).length;
              var text = "已处理 @a / @b 本".tlParams(
                  {"a": "$done", "b": "${widget.requests.length}"});
              // 全部处理完时补一段汇总, 省得自己数
              if (done == widget.requests.length &&
                  widget.requests.isNotEmpty) {
                var queued = results
                    .where((e) => e?.result == DownloadEnqueueResult.queued)
                    .length;
                var skipped = results
                    .where((e) => e?.result == DownloadEnqueueResult.skipped)
                    .length;
                var failed = results
                    .where((e) => e?.result == DownloadEnqueueResult.failed)
                    .length;
                text += "   ·   " +
                    "入队 @a · 跳过 @b · 失败 @c".tlParams({
                      "a": "$queued",
                      "b": "$skipped",
                      "c": "$failed",
                    });
              }
              return Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.outline,
                ),
              );
            },
          ),
        ],
      ),
      content: SizedBox(
        width: width,
        height: math.min(360.0, MediaQuery.of(context).size.height * 0.55),
        // 下载进度由 initState 里的定时器驱动刷新, 避免逐图重建
        child: ValueListenableBuilder<List<DownloadEnqueueOutcome?>>(
          valueListenable: widget.progress,
          builder: (context, results, _) {
            return ValueListenableBuilder<int>(
              valueListenable: widget.currentIndex,
              builder: (context, current, _) {
                return ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: widget.requests.length,
                  itemBuilder: (context, i) => _buildEntry(context, i,
                      results[i], current == i, results[i] == null),
                );
              },
            );
          },
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        ValueListenableBuilder<bool>(
          valueListenable: widget.running,
          builder: (context, isRunning, _) {
            if (isRunning) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: widget.onCancel, child: Text("中断".tl)),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: widget.onClose, child: Text("后台运行".tl)),
                ],
              );
            }
            return ValueListenableBuilder<List<DownloadEnqueueOutcome?>>(
              valueListenable: widget.progress,
              builder: (context, results, _) {
                var failed = <int>[
                  for (var i = 0; i < results.length; i++)
                    if (results[i]?.result == DownloadEnqueueResult.failed) i,
                ];
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () {
                        widget.onClose();
                        App.globalTo(() => const DownloadPage());
                      },
                      child: Text("查看下载".tl),
                    ),
                    if (failed.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: () => widget.onRetry(failed),
                        child: Text("重试失败项 (@a)".tlParams({
                          "a": "${failed.length}",
                        })),
                      ),
                    ],
                    const SizedBox(width: 8),
                    FilledButton(
                        onPressed: widget.onClose, child: Text("关闭".tl)),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  /// 一本书的整块内容: 汇总行 + (展开时的)逐话明细
  Widget _buildEntry(BuildContext context, int index,
      DownloadEnqueueOutcome? outcome, bool isCurrent, bool pending) {
    var scheme = Theme.of(context).colorScheme;
    var request = widget.requests[index];

    var (IconData icon, Color? color, String status) = switch (outcome?.result) {
      null when isCurrent => (Icons.sync, scheme.primary, "处理中…".tl),
      null => (Icons.schedule, null, "等待中".tl),
      DownloadEnqueueResult.queued =>
        (Icons.check_circle, Colors.green, "已加入队列".tl),
      DownloadEnqueueResult.skipped =>
        (Icons.remove_circle_outline, null, "已下载, 跳过".tl),
      DownloadEnqueueResult.failed =>
        (Icons.error_outline, scheme.error, "失败".tl),
    };

    var summary = outcome?.summary ?? "";
    var canExpand = (outcome?.epIds?.isNotEmpty ?? false);
    var isExpanded = _expanded.contains(index);
    var progress = _queueProgress(request.key, request.target);
    var failedMessage = outcome?.result == DownloadEnqueueResult.failed
        ? outcome?.message
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: canExpand ? () => _toggleExpanded(index) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                if (isCurrent && pending)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        request.title.replaceAll("\n", ""),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      if (summary.isNotEmpty)
                        Text(
                          summary,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.outline,
                          ),
                        ),
                      if (failedMessage != null)
                        Text(
                          failedMessage,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (progress != null && progress.total > 0)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "${progress.done}/${progress.total}页",
                        style: TextStyle(fontSize: 12, color: color),
                      ),
                      const SizedBox(height: 3),
                      SizedBox(
                        width: 64,
                        child: LinearProgressIndicator(
                          value: (progress.done / progress.total).clamp(0.0, 1.0).toDouble(),
                          minHeight: 4,
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    status,
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                if (canExpand)
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.outline,
                  ),
              ],
            ),
          ),
        ),
        if (isExpanded) _buildEpDetail(context, index, outcome),
      ],
    );
  }

  /// 展开后的逐话页数; 加载中显示进度
  Widget _buildEpDetail(
      BuildContext context, int index, DownloadEnqueueOutcome? outcome) {
    var scheme = Theme.of(context).colorScheme;
    if (_loading.contains(index)) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(44, 2, 8, 8),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text("正在读取每话页数…".tl,
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ],
        ),
      );
    }
    var pages = _epPages[index];
    var epIds = outcome?.epIds ?? const <String>[];
    if (pages == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < epIds.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "第 @c 话".tlParams({"c": "${i + 1}"}),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    i < pages.length && pages[i] != null
                        ? "@c页".tlParams({"c": "${pages[i]}"})
                        : "页数未知".tl,
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Future<DownloadEnqueueOutcome> _downloadPicacg(
    String target, String downloadId, bool selectChapter, bool silent) async {
  final res = await PicacgNetwork().getComicInfo(target);
  if (res.error) {
    if (!silent) {
      showToast(message: res.errorMessage ?? "Error");
    }
    return DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
        message: res.errorMessage);
  }
  final comic = res.data;
  var epIds = List<String>.generate(comic.eps.length, (i) => "$i");
  var outcomeBase = (
    epCount: comic.eps.length,
    pageCount: comic.pagesCount > 0 ? comic.pagesCount : null,
    epIds: epIds,
  );
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(comic.eps, downloaded);
    if (missing.isEmpty) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return DownloadEnqueueOutcome(DownloadEnqueueResult.skipped,
          epCount: outcomeBase.epCount,
          pageCount: outcomeBase.pageCount,
          epIds: outcomeBase.epIds,
          message: "已下载");
    }
    DownloadManager().addPicDownload(comic, missing);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
        epCount: outcomeBase.epCount,
        pageCount: outcomeBase.pageCount,
        epIds: outcomeBase.epIds);
  }
  _showChapterSelector(comic.eps, downloaded, (selected) {
    DownloadManager().addPicDownload(comic, selected);
  });
  return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
      epCount: outcomeBase.epCount,
      pageCount: outcomeBase.pageCount,
      epIds: outcomeBase.epIds);
}

Future<DownloadEnqueueOutcome> _downloadJm(
    String target, String downloadId, bool selectChapter, bool silent) async {
  final res = await JmNetwork().getComicInfo(target);
  if (res.error) {
    if (!silent) {
      showToast(message: res.errorMessage ?? "Error");
    }
    return DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
        message: res.errorMessage);
  }
  final comic = res.data;
  List<String> eps;
  if (comic.series.isEmpty) {
    eps = ["第1章".tl];
  } else {
    eps = List<String>.generate(comic.series.length,
        (index) => "第 @c 章".tlParams({"c": (index + 1).toString()}));
  }
  // 禁漫的漫画信息里没有页数, 只给话数; 展开时才逐话查询
  // (series 为空即单话, 此时不提供展开)
  var epIds = comic.series.values.map((e) => e.toString()).toList();
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(eps, downloaded);
    if (missing.isEmpty) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return DownloadEnqueueOutcome(DownloadEnqueueResult.skipped,
          epCount: eps.length, epIds: epIds, message: "已下载");
    }
    DownloadManager().addJmDownload(comic, missing);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
        epCount: eps.length, epIds: epIds);
  }
  _showChapterSelector(eps, downloaded, (selected) {
    DownloadManager().addJmDownload(comic, selected);
  });
  return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
      epCount: eps.length, epIds: epIds);
}

Future<DownloadEnqueueOutcome> _downloadCustomSource(String sourceKey,
    String target, String downloadId, bool selectChapter, bool silent) async {
  final source = ComicSource.find(sourceKey);
  if (source == null || source.loadComicInfo == null) {
    if (!silent) {
      showToast(message: "该漫画源不支持下载".tl);
    }
    return const DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
        message: "该漫画源不支持下载");
  }
  final res = await source.loadComicInfo!(target);
  if (res.error) {
    if (!silent) {
      showToast(message: res.errorMessage ?? "Error");
    }
    return DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
        message: res.errorMessage);
  }
  final data = res.data;
  final chapters = data.chapters;
  final eps = chapters?.values.toList();
  if (eps == null || eps.isEmpty) {
    // 单话漫画, 没有章节可选
    if (DownloadManager().isExists(downloadId) ||
        _isInDownloadingQueue(downloadId)) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return const DownloadEnqueueOutcome(DownloadEnqueueResult.skipped,
          epCount: 1, message: "已下载");
    }
    DownloadManager().addCustomDownload(data, [0]);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return const DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
        epCount: 1);
  }
  var epIds = chapters!.keys.toList();
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(eps, downloaded);
    if (missing.isEmpty) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return DownloadEnqueueOutcome(DownloadEnqueueResult.skipped,
          epCount: eps.length, epIds: epIds, message: "已下载");
    }
    DownloadManager().addCustomDownload(data, missing);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
        epCount: eps.length, epIds: epIds);
  }
  _showChapterSelector(eps, downloaded, (selected) {
    DownloadManager().addCustomDownload(data, selected);
  });
  return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
      epCount: eps.length, epIds: epIds);
}

/// e-hentai / hitomi / 绅士漫画 / nhentai: 一本即全部内容。
///
/// [silent] 为 true(批量下载)时跳过单本确认框 —— 否则多选 N 本要点 N 次。
Future<DownloadEnqueueOutcome> _downloadWholeComic(String sourceKey,
    String target, String title, String downloadId, bool silent) async {
  if (DownloadManager().isExists(downloadId)) {
    if (!silent) {
      showToast(message: "已下载".tl);
    }
    return const DownloadEnqueueOutcome(DownloadEnqueueResult.skipped,
        epCount: 1, message: "已下载");
  }
  if (!silent && !await _confirmDownload(title)) {
    return const DownloadEnqueueOutcome(DownloadEnqueueResult.skipped,
        message: "已取消");
  }
  switch (sourceKey) {
    case 'ehentai':
      final res = await EhNetwork().getGalleryInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
            message: res.errorMessage);
      }
      DownloadManager().addEhDownload(res.data);
      if (!silent) {
        showToast(message: "已加入下载队列".tl);
      }
      // E 站的详情里只有分页大小, 没有总页数, 因此只显示话数
      return const DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
          epCount: 1);
    case 'hitomi':
      final res = await HiNetwork().getComicInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
            message: res.errorMessage);
      }
      var pages = res.data.files.length;
      DownloadManager().addHitomiDownload(res.data, res.data.cover, target);
      if (!silent) {
        showToast(message: "已加入下载队列".tl);
      }
      return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
          epCount: 1, pageCount: pages > 0 ? pages : null);
    case 'htmanga':
      final res = await HtmangaNetwork().getComicInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
            message: res.errorMessage);
      }
      DownloadManager().addHtDownload(res.data);
      if (!silent) {
        showToast(message: "已加入下载队列".tl);
      }
      return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
          epCount: 1, pageCount: res.data.pages > 0 ? res.data.pages : null);
    case 'nhentai':
      final res = await NhentaiNetwork().getComicInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueOutcome(DownloadEnqueueResult.failed,
            message: res.errorMessage);
      }
      DownloadManager().addNhentaiDownload(res.data);
      if (!silent) {
        showToast(message: "已加入下载队列".tl);
      }
      var thumbs = res.data.thumbnails.length;
      return DownloadEnqueueOutcome(DownloadEnqueueResult.queued,
          epCount: 1, pageCount: thumbs > 0 ? thumbs : null);
    default:
      return const DownloadEnqueueOutcome(DownloadEnqueueResult.failed);
  }
}
