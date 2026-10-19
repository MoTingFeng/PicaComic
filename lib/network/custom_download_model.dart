import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
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

  /// 取不到图片的话(通常是需要购买或更高等级的"卷")。
  /// 这些话下载时跳过, 不影响其余话, 也不会被标成「已下载」。
  final List<int> skippedEps = [];

  Future<void> getOneEp(int i, Map<int, List<String>> links) async {
    if (links[i + 1] != null) return;

    var ep = comic.chapters!.keys.elementAt(i);
    String? lastError;

    for (var retry = 0; retry < 3; retry++) {
      var res = await source.loadComicPages!(comic.comicId, ep);
      if (!res.error) {
        links[i + 1] = res.data;
        return;
      }
      /// 记下源给的真实原因(例如"该章节需要登录或更高账号权限"),
      /// 别再统一成 Failed to get chapters —— 否则日志里看不出问题在哪
      lastError = res.errorMessage;
      await Future.delayed(const Duration(seconds: 3));
    }

    throw Exception(lastError ?? "Failed to get chapters");
  }

  /// 取一话的图片列表, 失败只记账不外抛 —— 否则 Future.wait 会让整本下载失败,
  /// start() 走 catch 分支反复 retry, 连能下的那几话也一起卡在「获取图片信息」。
  Future<void> _fetchOneEp(int i, Map<int, List<String>> links) async {
    try {
      await getOneEp(i, links);
    } catch (e) {
      skippedEps.add(i);
      LogManager.addLog(
          LogLevel.warning, "Download", "跳过第 ${i + 1} 话(取不到图片): $e");
    }
  }

  @override
  Future<Map<int, List<String>>> getLinks() async {
    var links = <int, List<String>>{};
    if (comic.chapters != null) {
      /// 这个阶段要逐话请求图片列表, 话多时可能持续几十秒(每话之间还有
      /// 200ms 节流)。不报进度的话界面会一直停在「获取图片信息...」,
      /// 看起来像卡死, 所以每完成一批就记录进度并通知界面刷新。
      /// 进度按"已处理的话数"算(含取不到的话), 否则有话说取不到时数字走不完。
      linkTotal = _downloadEps.length;
      linkDone = 0;
      skippedEps.clear();
      var handled = 0;
      var futures = <Future>[];
      for (var i in _downloadEps) {
        futures.add(_fetchOneEp(i, links).whenComplete(() {
          handled++;
          linkDone = handled;
          updateInfo?.call();
        }));
        await Future.delayed(const Duration(milliseconds: 200));
        if (futures.length % 5 == 0) {
          await Future.wait(futures);
          futures.clear();
          updateInfo?.call();
        }
      }
      await Future.wait(futures);
      updateInfo?.call();
      if (links.isEmpty && _downloadEps.isNotEmpty) {
        throw Exception("选中的 ${_downloadEps.length} 话都取不到图片");
      }
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
  Future<DownloadedItem> toDownloadedItem() => _buildDownloadedItem(
      _downloadEps.where((e) => !skippedEps.contains(e)).toList());

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
    /// links 的 key 是 1-based 话序号, 且只含真的取到图片的话 —— 跳过的话不在里面,
    /// 所以不能再用 _downloadEps.take() 推断(有跳过时两者会错位)。
    var done = links!.keys.take(downloadingEp).map((e) => e - 1).toList();
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
