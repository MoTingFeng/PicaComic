import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/io_tools.dart';
import '../../base.dart';
import '../download.dart';
import 'methods.dart';
import 'models.dart';
import 'dart:io';

class DownloadedComic extends DownloadedItem {
  ComicItem comicItem;
  List<String> chapters;
  List<int> downloadedChapters;
  double? size;

  DownloadedComic(
      this.comicItem, this.chapters, this.size, this.downloadedChapters);

  @override
  Map<String, dynamic> toJson() => {
        "comicItem": comicItem.toJson(),
        "chapters": chapters,
        "size": size,
        "downloadedChapters": downloadedChapters
      };

  DownloadedComic.fromJson(Map<String, dynamic> json)
      : comicItem = ComicItem.fromJson(json["comicItem"]),
        chapters = List<String>.from(json["chapters"]),
        size = json["size"],
        downloadedChapters = [] {
    if (json["downloadedChapters"] == null) {
      //旧版本中的数据不包含这一项
      for (int i = 0; i < chapters.length; i++) {
        downloadedChapters.add(i);
      }
    } else {
      downloadedChapters = List<int>.from(json["downloadedChapters"]);
    }
  }

  @override
  DownloadType get type => DownloadType.picacg;

  @override
  List<int> get downloadedEps => downloadedChapters;

  @override
  List<String> get eps => chapters.getNoBlankList();

  @override
  String get name => comicItem.title;

  @override
  String get id => comicItem.id;

  @override
  String get subTitle => comicItem.author;

  @override
  double? get comicSize => size;

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => comicItem.tags;
}

///picacg的下载进程模型
class PicDownloadingItem extends DownloadingItem {
  PicDownloadingItem(this.comic, this._downloadEps, super.whenFinish,
      super.whenError, super.updateInfo, super.id,
      {super.type = DownloadType.picacg});

  ///漫画模型
  final ComicItem comic;

  ///章节名称
  var _eps = <String>[];

  ///要下载的章节序号
  final List<int> _downloadEps;

  ///获取各章节名称
  List<String> get eps => _eps;

  @override
  get cover => getImageUrl(comic.thumbUrl);

  @override
  String get title => comic.title;

  /// 正在预取的话(数字是话号), 避免同一话重复请求
  final _prefetching = <int>{};

  @override
  int get totalEps => _downloadEps.isEmpty ? 1 : _downloadEps.length;

  @override
  Future<Map<int, List<String>>> getLinks() async {
    _eps = (await network.getEps(id)).data;
    linkTotal = _downloadEps.length;
    var res = <int, List<String>>{};
    if (_downloadEps.isEmpty) {
      return res;
    }
    // 只取当前要下的这一话, 其余等 ensureEpLinks 按需取:
    // 哔咔一本一百话, 全部预先取完就是一百次串行请求, 期间一张图都下不了。
    var position = downloadingEp.clamp(0, _downloadEps.length - 1);
    var ep = _downloadEps[position] + 1;
    res[ep] = (await network.getComicContent(id, ep)).data;
    linkDone = position + 1;
    _prefetch(ep);
    return res;
  }

  @override
  Future<int> ensureEpLinks(int position) async {
    var pos = position.clamp(0, _downloadEps.length - 1);
    var ep = _downloadEps[pos] + 1;
    links ??= <int, List<String>>{};
    if (links![ep] == null) {
      links![ep] = (await network.getComicContent(id, ep)).data;
    }
    linkDone = pos + 1;
    updateInfo?.call();
    _prefetch(ep);
    return ep;
  }

  /// 预取后面两话的图片地址, 让"取链接"和"下图片"重叠起来;
  /// 预取失败不影响下载, 真下到那一话时会重新取。
  void _prefetch(int currentEp) {
    if (_downloadEps.isEmpty) {
      return;
    }
    var current = _downloadEps.indexOf(currentEp - 1);
    if (current < 0) {
      return;
    }
    for (var step = 1; step <= 2; step++) {
      var pos = current + step;
      if (pos >= _downloadEps.length) {
        return;
      }
      var ep = _downloadEps[pos] + 1;
      if (links?[ep] != null || _prefetching.contains(ep)) {
        continue;
      }
      unawaited(_prefetchOne(ep));
    }
  }

  Future<void> _prefetchOne(int ep) async {
    _prefetching.add(ep);
    try {
      var r = await network.getComicContent(id, ep);
      links?[ep] = r.data;
    } catch (e) {
      LogManager.addLog(
          LogLevel.warning, "Download", "预取第 $ep 话的图片地址失败: $e");
    } finally {
      _prefetching.remove(ep);
      updateInfo?.call();
    }
  }

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    return ImageManager().getImage(getImageUrl(link));
  }

  @override
  bool canStreamImage(String link) => true;

  @override
  Future<String> downloadImageToFile(String link, File file,
      {void Function(int bytes)? onProgress,
      bool Function()? isCanceled}) {
    return ImageManager().downloadToFile(getImageUrl(link), file,
        onProgress: onProgress, isCanceled: isCanceled);
  }

  @override
  Map<String, dynamic> toMap() => {
        "comic": comic.toJson(),
        "_eps": _eps,
        "_downloadEps": _downloadEps,
        ...super.toBaseMap()
      };

  PicDownloadingItem.fromMap(
      Map<String, dynamic> map,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : comic = ComicItem.fromJson(map["comic"]),
        _eps = List<String>.from(map["_eps"]),
        _downloadEps = List<int>.from(map["_downloadEps"]),
        super.fromMap(map, whenFinish, whenError, updateInfo);

  @override
  FutureOr<DownloadedItem> toDownloadedItem() async {
    var previous = <int>[];
    if (DownloadManager().isExists(id)) {
      var comic =
          (await DownloadManager().getComicOrNull(id))! as DownloadedComic;
      previous = comic.downloadedEps;
    }
    var downloaded = (_downloadEps + previous).toSet().toList();
    downloaded.sort();
    return DownloadedComic(
      comic,
      eps,
      await getFolderSize(Directory(path)),
      downloaded,
    );
  }
}
