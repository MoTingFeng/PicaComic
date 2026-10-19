import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/download_model.dart';

import '../tools/io_tools.dart';
import 'download.dart';

class CustomDownloadedItem extends DownloadedItem {
  @override
  double? comicSize;

  @override
  final List<int> downloadedEps;

  final Map<String, String>? chapters;

  @override
  List<String> get eps => chapters?.values.toList() ?? ["EP 1"];

  final String comicId;

  @override
  final String id;

  @override
  final String name;

  @override
  final String subTitle;

  @override
  final List<String> tags;

  @override
  DownloadType get type => DownloadType.other;

  final String sourceKey;

  final String sourceName;

  final String cover;

  CustomDownloadedItem(
      this.comicSize,
      this.downloadedEps,
      this.chapters,
      this.id,
      this.name,
      this.subTitle,
      this.tags,
      this.sourceKey,
      this.sourceName,
      this.cover,
      this.comicId);

  @override
  Map<String, dynamic> toJson() => {
        "comicSize": comicSize,
        "downloadedEps": downloadedEps,
        "chapters": chapters,
        "id": id,
        "name": name,
        "subTitle": subTitle,
        "tags": tags,
        "sourceKey": sourceKey,
        "sourceName": sourceName,
        "cover": cover,
        "comicId": comicId
      };

  CustomDownloadedItem.fromJson(Map<String, dynamic> json)
      : comicSize = json["comicSize"],
        downloadedEps = List<int>.from(json["downloadedEps"]),
        chapters = Map<String, String>.from(json["chapters"]),
        id = json["id"],
        name = json["name"],
        subTitle = json["subTitle"],
        tags = List<String>.from(json["tags"]),
        sourceKey = json["sourceKey"],
        sourceName = json["sourceName"],
        cover = json["cover"],
        comicId = json["comicId"];
}

class CustomDownloadingItem extends DownloadingItem {
  CustomDownloadingItem(this.comic, this._downloadEps, super.whenFinish,
      super.whenError, super.updateInfo, super.id,
      {super.type = DownloadType.other})
      : source = ComicSource.find(comic.sourceKey)!;

  final ComicInfoData comic;

  final List<int> _downloadEps;

  late final ComicSource source;

  /// JS 源都属于 DownloadType.other, 并发调度必须按真实的源 key 分组,
  /// 否则再漫画和拷贝漫画会被当成同一个源而互相排队
  @override
  String get sourceKey => comic.sourceKey;

  @override
  String get cover => comic.cover;

  @override
  bool get haveEps => comic.chapters != null;

  Stream<DownloadProgress> _getImage(String url) {
    if (source.getImageLoadingConfig != null) {
      int ep = links!.keys.elementAt(downloadingEp);
      var config = source.getImageLoadingConfig!(url, comic.comicId,
          comic.chapters?.keys.elementAtOrNull(ep - 1) ?? comic.comicId);
      return ImageManager()
          .getImage(config["url"] ?? url, Map.from(config['headers'] ?? {}));
    }
    return ImageManager().getImage(url);
  }

  @override
  Map<String, String> get headers => {
        "User-Agent": webUA,
      };

  Future<void> getOneEp(int i, Map<int, List<String>> links) async {
    if (links[i + 1] != null) return;

    int retry = 0;

    while (retry < 3) {
      try {
        links[i + 1] = (await source.loadComicPages!(
                comic.comicId, comic.chapters!.keys.elementAt(i)))
            .data;
        return;
      } catch (e) {
        await Future.delayed(const Duration(seconds: 3));
        retry++;
      }
    }

    throw Exception("Failed to get chapters");
  }

  @override
  Future<Map<int, List<String>>> getLinks() async {
    var links = <int, List<String>>{};
    if (comic.chapters != null) {
      /// 这个阶段要逐话请求图片列表, 话多时可能持续几十秒(每话之间还有
      /// 200ms 节流)。不报进度的话界面会一直停在「获取图片信息...」,
      /// 看起来像卡死, 所以每完成一批就记录进度并通知界面刷新。
      linkTotal = _downloadEps.length;
      linkDone = 0;
      var futures = <Future>[];
      for (var i in _downloadEps) {
        futures.add(getOneEp(i, links));
        await Future.delayed(const Duration(milliseconds: 200));
        if (futures.length % 5 == 0) {
          await Future.wait(futures);
          futures.clear();
          linkDone = links.length;
          updateInfo?.call();
        }
      }
      await Future.wait(futures);
      linkDone = links.length;
      updateInfo?.call();
    } else {
      var res = await source.loadComicPages!(comic.comicId, null);
      links[0] = res.data;
    }
    return links;
  }

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toMap() => {
        "comic": comic.toJson(),
        "_downloadEps": _downloadEps,
        ...super.toBaseMap()
      };

  CustomDownloadingItem.fromMap(
      Map<String, dynamic> map,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : comic = ComicInfoData.fromJson(map["comic"]),
        _downloadEps = List<int>.from(map["_downloadEps"]),
        super.fromMap(map, whenFinish, whenError, updateInfo) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  @override
  Future<DownloadedItem> toDownloadedItem() => _buildDownloadedItem(_downloadEps);

  /// 已经写进「已下载」列表的话数, 避免同一话重复写库
  int _syncedEps = 0;

  /// 已统计过体积的话数 与 累计体积(MB)。
  /// 下载中要显示真实体积, 又不能每话都全量扫整本目录(话越多越慢),
  /// 所以只统计新增的话并累加。
  int _sizedEps = 0;
  double _knownSize = 0;

  /// [eps] 本次算作「已下载」的话(0-based 话序号)。
  /// 整本下完时传全部 _downloadEps; 中途同步只传已下完的那部分 ——
  /// 否则没下的话也会被标成可读, 点进去会找不到文件。
  /// [size] 直接给定体积(MB); 不传则全量扫目录(整本下完时用)。
  Future<CustomDownloadedItem> _buildDownloadedItem(List<int> eps,
      {double? size}) async {
    var previous = <int>[];
    if (DownloadManager().isExists(id)) {
      var comic = await DownloadManager().getComicOrNull(id);
      previous = comic!.downloadedEps;
    }
    var downloaded = (eps + previous).toSet().toList();
    downloaded.sort();
    var tags = <String>[];
    comic.tags.forEach((key, value) => tags.addAll(value));
    return CustomDownloadedItem(
      size ?? await getFolderSize(Directory(path)),
      downloaded,
      comic.chapters,
      id,
      comic.title,
      comic.subTitle ?? "",
      tags,
      comic.sourceKey,
      source.name,
      comic.cover,
      comic.comicId,
    );
  }

  @override
  Future<void> onEpisodeDownloaded() async {
    if (directory == null) return;
    var done = _downloadEps.take(downloadingEp).toList();
    if (done.isEmpty) return;

    /// 只扫这一话新增的目录并累加, 让「已下载」里显示的是真实体积而不是 0.00MB
    for (var i = _sizedEps; i < done.length; i++) {
      var epDir = Directory("$path/${done[i] + 1}");
      if (epDir.existsSync()) {
        _knownSize += await getFolderSize(epDir);
      }
    }
    _sizedEps = done.length;

    if (done.length == _syncedEps) return;
    /// 「已下载」区域只在第一话下完时刷一次, 后面各话只更新数据库不刷页面,
    /// 免得用户正在看的列表反复跳动(整本下完时 onTaskFinished 会再刷一次)。
    var firstEpisode = _syncedEps == 0;
    _syncedEps = done.length;
    DownloadManager().addPartiallyDownloaded(
        await _buildDownloadedItem(done, size: _knownSize), directory!,
        refresh: firstEpisode);
  }

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    return _getImage(link);
  }
}
