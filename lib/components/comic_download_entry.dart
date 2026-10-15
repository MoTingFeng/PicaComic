part of 'components.dart';

/// 支持按章节选择下载的内置源：下载接口带章节参数。
const _wholeComicSources = {'ehentai', 'hitomi', 'htmanga', 'nhentai'};

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
Future<void> downloadComicDirectly({
  required String sourceKey,
  required String target,
  required String title,
  bool selectChapter = true,
}) async {
  final downloadId = _downloadIdOf(sourceKey, target);
  if (_isInDownloadingQueue(downloadId)) {
    showToast(message: "下载中".tl);
    return;
  }

  if (sourceKey == 'picacg') {
    await _downloadPicacg(target, downloadId, selectChapter);
  } else if (sourceKey == 'jm') {
    await _downloadJm(target, downloadId, selectChapter);
  } else if (_wholeComicSources.contains(sourceKey)) {
    await _downloadWholeComic(sourceKey, target, title, downloadId);
  } else {
    await _downloadCustomSource(sourceKey, target, downloadId, selectChapter);
  }
}

/// 批量下载: 先确认一次, 再逐本入队(不弹章节框, 只补缺)。
Future<void> downloadComicsDirectly(
    List<({String key, String target, String title})> requests) async {
  if (requests.isEmpty) {
    showToast(message: "所选漫画不支持直接下载".tl);
    return;
  }
  if (!await _confirmDownload("", count: requests.length)) {
    return;
  }
  var cancel = false;
  var dialog = showLoadingDialog(
    App.globalContext!,
    onCancel: () => cancel = true,
  );
  for (var request in requests) {
    if (cancel) {
      break;
    }
    await downloadComicDirectly(
      sourceKey: request.key,
      target: request.target,
      title: request.title,
      selectChapter: false,
    );
  }
  dialog.close();
}

Future<void> _downloadPicacg(
    String target, String downloadId, bool selectChapter) async {
  final res = await PicacgNetwork().getComicInfo(target);
  if (res.error) {
    showToast(message: res.errorMessage ?? "Error");
    return;
  }
  final comic = res.data;
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(comic.eps, downloaded);
    if (missing.isEmpty) {
      showToast(message: "已下载".tl);
      return;
    }
    DownloadManager().addPicDownload(comic, missing);
    showToast(message: "已加入下载队列".tl);
    return;
  }
  _showChapterSelector(comic.eps, downloaded, (selected) {
    DownloadManager().addPicDownload(comic, selected);
  });
}

Future<void> _downloadJm(
    String target, String downloadId, bool selectChapter) async {
  final res = await JmNetwork().getComicInfo(target);
  if (res.error) {
    showToast(message: res.errorMessage ?? "Error");
    return;
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
      showToast(message: "已下载".tl);
      return;
    }
    DownloadManager().addJmDownload(comic, missing);
    showToast(message: "已加入下载队列".tl);
    return;
  }
  _showChapterSelector(eps, downloaded, (selected) {
    DownloadManager().addJmDownload(comic, selected);
  });
}

Future<void> _downloadCustomSource(String sourceKey, String target,
    String downloadId, bool selectChapter) async {
  final source = ComicSource.find(sourceKey);
  if (source == null || source.loadComicInfo == null) {
    showToast(message: "该漫画源不支持下载".tl);
    return;
  }
  final res = await source.loadComicInfo!(target);
  if (res.error) {
    showToast(message: res.errorMessage ?? "Error");
    return;
  }
  final data = res.data;
  final eps = data.chapters?.values.toList();
  if (eps == null || eps.isEmpty) {
    // 单话漫画, 没有章节可选
    if (DownloadManager().isExists(downloadId) ||
        _isInDownloadingQueue(downloadId)) {
      showToast(message: "已下载".tl);
      return;
    }
    DownloadManager().addCustomDownload(data, [0]);
    showToast(message: "已加入下载队列".tl);
    return;
  }
  var downloaded = await _downloadedEpsOf(downloadId);
  if (!selectChapter) {
    var missing = _missingEps(eps, downloaded);
    if (missing.isEmpty) {
      showToast(message: "已下载".tl);
      return;
    }
    DownloadManager().addCustomDownload(data, missing);
    showToast(message: "已加入下载队列".tl);
    return;
  }
  _showChapterSelector(eps, downloaded, (selected) {
    DownloadManager().addCustomDownload(data, selected);
  });
}

/// e-hentai / hitomi / 绅士漫画 / nhentai: 一本即全部内容, 确认后整本下载。
Future<void> _downloadWholeComic(
    String sourceKey, String target, String title, String downloadId) async {
  if (DownloadManager().isExists(downloadId)) {
    showToast(message: "已下载".tl);
    return;
  }
  if (!await _confirmDownload(title)) {
    return;
  }
  switch (sourceKey) {
    case 'ehentai':
      final res = await EhNetwork().getGalleryInfo(target);
      if (res.error) {
        showToast(message: res.errorMessage ?? "Error");
        return;
      }
      DownloadManager().addEhDownload(res.data);
      break;
    case 'hitomi':
      final res = await HiNetwork().getComicInfo(target);
      if (res.error) {
        showToast(message: res.errorMessage ?? "Error");
        return;
      }
      DownloadManager().addHitomiDownload(res.data, res.data.cover, target);
      break;
    case 'htmanga':
      final res = await HtmangaNetwork().getComicInfo(target);
      if (res.error) {
        showToast(message: res.errorMessage ?? "Error");
        return;
      }
      DownloadManager().addHtDownload(res.data);
      break;
    case 'nhentai':
      final res = await NhentaiNetwork().getComicInfo(target);
      if (res.error) {
        showToast(message: res.errorMessage ?? "Error");
        return;
      }
      DownloadManager().addNhentaiDownload(res.data);
      break;
    default:
      return;
  }
  showToast(message: "已加入下载队列".tl);
}
