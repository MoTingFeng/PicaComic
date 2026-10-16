part of 'components.dart';

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
Future<DownloadEnqueueResult> downloadComicDirectly({
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
    return DownloadEnqueueResult.skipped;
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
/// 面板会列出每一本漫画及其状态(等待中/处理中/已加入队列/已下载跳过/失败),
/// 处理过程中可中断, 剩余的不再入队。
Future<void> downloadComicsDirectly(
    List<({String key, String target, String title})> requests) async {
  if (requests.isEmpty) {
    showToast(message: "所选漫画不支持直接下载".tl);
    return;
  }
  if (!await _confirmDownload("", count: requests.length)) {
    return;
  }

  var progress = ValueNotifier<List<DownloadEnqueueResult?>>(
      List<DownloadEnqueueResult?>.filled(requests.length, null));
  var currentIndex = ValueNotifier<int>(-1);
  var running = ValueNotifier<bool>(true);
  var cancelled = false;

  showDialog(
    context: App.globalContext!,
    barrierDismissible: false,
    builder: (dialogContext) => _BatchDownloadPanel(
      requests: requests,
      progress: progress,
      currentIndex: currentIndex,
      running: running,
      onCancel: () => cancelled = true,
      onClose: () {
        if (dialogContext.mounted) {
          dialogContext.pop();
        }
      },
    ),
  );

  for (var i = 0; i < requests.length; i++) {
    if (cancelled) {
      break;
    }
    currentIndex.value = i;
    var result = await downloadComicDirectly(
      sourceKey: requests[i].key,
      target: requests[i].target,
      title: requests[i].title,
      selectChapter: false,
      silent: true,
    );
    var next = List<DownloadEnqueueResult?>.from(progress.value);
    next[i] = result;
    progress.value = next;
  }
  currentIndex.value = -1;
  running.value = false;
}

/// 批量下载进度面板。
class _BatchDownloadPanel extends StatelessWidget {
  const _BatchDownloadPanel({
    required this.requests,
    required this.progress,
    required this.currentIndex,
    required this.running,
    required this.onCancel,
    required this.onClose,
  });

  final List<({String key, String target, String title})> requests;
  final ValueNotifier<List<DownloadEnqueueResult?>> progress;
  final ValueNotifier<int> currentIndex;
  final ValueNotifier<bool> running;
  final void Function() onCancel;
  final void Function() onClose;

  @override
  Widget build(BuildContext context) {
    var width = math.min(400.0, MediaQuery.of(context).size.width - 64);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("批量加入下载队列".tl, style: const TextStyle(fontSize: 19)),
          const SizedBox(
            height: 4,
          ),
          ValueListenableBuilder<List<DownloadEnqueueResult?>>(
            valueListenable: progress,
            builder: (context, results, _) {
              var done = results.where((e) => e != null).length;
              return Text(
                "已处理 @a / @b 本".tlParams(
                    {"a": "$done", "b": "${requests.length}"}),
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
        height: math.min(340.0, MediaQuery.of(context).size.height * 0.5),
        child: ValueListenableBuilder<List<DownloadEnqueueResult?>>(
          valueListenable: progress,
          builder: (context, results, _) {
            return ValueListenableBuilder<int>(
              valueListenable: currentIndex,
              builder: (context, current, _) {
                return ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: requests.length,
                  itemBuilder: (context, i) => _buildRow(
                      context, i, results[i], current == i, results[i] == null),
                );
              },
            );
          },
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        ValueListenableBuilder<bool>(
          valueListenable: running,
          builder: (context, isRunning, _) {
            if (isRunning) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: onCancel, child: Text("中断".tl)),
                  const SizedBox(
                    width: 8,
                  ),
                  FilledButton(onPressed: onClose, child: Text("后台运行".tl)),
                ],
              );
            }
            return FilledButton(onPressed: onClose, child: Text("关闭".tl));
          },
        ),
      ],
    );
  }

  Widget _buildRow(BuildContext context, int index,
      DownloadEnqueueResult? result, bool isCurrent, bool pending) {
    var scheme = Theme.of(context).colorScheme;
    var (IconData icon, Color? color, String status) = switch (result) {
      null when isCurrent => (Icons.sync, scheme.primary, "处理中…".tl),
      null => (Icons.schedule, null, "等待中".tl),
      DownloadEnqueueResult.queued =>
        (Icons.check_circle, Colors.green, "已加入队列".tl),
      DownloadEnqueueResult.skipped =>
        (Icons.remove_circle_outline, null, "已下载, 跳过".tl),
      DownloadEnqueueResult.failed =>
        (Icons.error_outline, scheme.error, "失败".tl),
    };

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: isCurrent && pending
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 20, color: color),
      title: Text(
        requests[index].title.replaceAll("\n", ""),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      trailing: Text(
        status,
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }
}

Future<DownloadEnqueueResult> _downloadPicacg(
    String target, String downloadId, bool selectChapter, bool silent) async {
  final res = await PicacgNetwork().getComicInfo(target);
  if (res.error) {
    if (!silent) {
      showToast(message: res.errorMessage ?? "Error");
    }
    return DownloadEnqueueResult.failed;
  }
  final comic = res.data;
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(comic.eps, downloaded);
    if (missing.isEmpty) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return DownloadEnqueueResult.skipped;
    }
    DownloadManager().addPicDownload(comic, missing);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return DownloadEnqueueResult.queued;
  }
  _showChapterSelector(comic.eps, downloaded, (selected) {
    DownloadManager().addPicDownload(comic, selected);
  });
  return DownloadEnqueueResult.queued;
}

Future<DownloadEnqueueResult> _downloadJm(
    String target, String downloadId, bool selectChapter, bool silent) async {
  final res = await JmNetwork().getComicInfo(target);
  if (res.error) {
    if (!silent) {
      showToast(message: res.errorMessage ?? "Error");
    }
    return DownloadEnqueueResult.failed;
  }
  final comic = res.data;
  List<String> eps;
  if (comic.series.isEmpty) {
    eps = ["第1章".tl];
  } else {
    eps = List<String>.generate(comic.series.length,
        (index) => "第 @c 章".tlParams({"c": (index + 1).toString()}));
  }
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(eps, downloaded);
    if (missing.isEmpty) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return DownloadEnqueueResult.skipped;
    }
    DownloadManager().addJmDownload(comic, missing);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return DownloadEnqueueResult.queued;
  }
  _showChapterSelector(eps, downloaded, (selected) {
    DownloadManager().addJmDownload(comic, selected);
  });
  return DownloadEnqueueResult.queued;
}

Future<DownloadEnqueueResult> _downloadCustomSource(String sourceKey,
    String target, String downloadId, bool selectChapter, bool silent) async {
  final source = ComicSource.find(sourceKey);
  if (source == null || source.loadComicInfo == null) {
    if (!silent) {
      showToast(message: "该漫画源不支持下载".tl);
    }
    return DownloadEnqueueResult.failed;
  }
  final res = await source.loadComicInfo!(target);
  if (res.error) {
    if (!silent) {
      showToast(message: res.errorMessage ?? "Error");
    }
    return DownloadEnqueueResult.failed;
  }
  final data = res.data;
  final eps = data.chapters?.values.toList();
  if (eps == null || eps.isEmpty) {
    // 单话漫画, 没有章节可选
    if (DownloadManager().isExists(downloadId) ||
        _isInDownloadingQueue(downloadId)) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return DownloadEnqueueResult.skipped;
    }
    DownloadManager().addCustomDownload(data, [0]);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return DownloadEnqueueResult.queued;
  }
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(eps, downloaded);
    if (missing.isEmpty) {
      if (!silent) {
        showToast(message: "已下载".tl);
      }
      return DownloadEnqueueResult.skipped;
    }
    DownloadManager().addCustomDownload(data, missing);
    if (!silent) {
      showToast(message: "已加入下载队列".tl);
    }
    return DownloadEnqueueResult.queued;
  }
  _showChapterSelector(eps, downloaded, (selected) {
    DownloadManager().addCustomDownload(data, selected);
  });
  return DownloadEnqueueResult.queued;
}

/// e-hentai / hitomi / 绅士漫画 / nhentai: 一本即全部内容。
///
/// [silent] 为 true(批量下载)时跳过单本确认框 —— 否则多选 N 本要点 N 次。
Future<DownloadEnqueueResult> _downloadWholeComic(String sourceKey,
    String target, String title, String downloadId, bool silent) async {
  if (DownloadManager().isExists(downloadId)) {
    if (!silent) {
      showToast(message: "已下载".tl);
    }
    return DownloadEnqueueResult.skipped;
  }
  if (!silent && !await _confirmDownload(title)) {
    return DownloadEnqueueResult.skipped;
  }
  switch (sourceKey) {
    case 'ehentai':
      final res = await EhNetwork().getGalleryInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueResult.failed;
      }
      DownloadManager().addEhDownload(res.data);
      break;
    case 'hitomi':
      final res = await HiNetwork().getComicInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueResult.failed;
      }
      DownloadManager().addHitomiDownload(res.data, res.data.cover, target);
      break;
    case 'htmanga':
      final res = await HtmangaNetwork().getComicInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueResult.failed;
      }
      DownloadManager().addHtDownload(res.data);
      break;
    case 'nhentai':
      final res = await NhentaiNetwork().getComicInfo(target);
      if (res.error) {
        if (!silent) {
          showToast(message: res.errorMessage ?? "Error");
        }
        return DownloadEnqueueResult.failed;
      }
      DownloadManager().addNhentaiDownload(res.data);
      break;
    default:
      return DownloadEnqueueResult.failed;
  }
  if (!silent) {
    showToast(message: "已加入下载队列".tl);
  }
  return DownloadEnqueueResult.queued;
}
