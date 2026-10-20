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
      /// 用 "本次下到第几话" 直接取话序号。不能再用 links.keys.elementAt():
      /// 懒加载/地址重取之后 links 里未必留着前面几话, 按下标取会取错话。
      var epIndex = _downloadEps.elementAtOrNull(downloadingEp);
      var chapterId = epIndex == null
          ? comic.comicId
          : (comic.chapters?.keys.elementAtOrNull(epIndex) ?? comic.comicId);
      var config = source.getImageLoadingConfig!(url, comic.comicId, chapterId);
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

  /// 本次要下的话数(懒加载靠它决定循环到哪)
  @override
  int get totalEps => comic.chapters == null ? 1 : _downloadEps.length;

  /// 下载页用"话"显示进度: 后面的地址还没取, 总页数不可知
  @override
  int? get episodeDone => comic.chapters == null ? null : _downloadingEp;

  @override
  int? get episodeTotal => comic.chapters == null ? null : _downloadEps.length;

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
      /// 这类是确定性失败(需购买/已删除), 重试只是白等
      if (lastError != null &&
          (lastError.contains("不可阅读") ||
              lastError.contains("不存在") ||
              lastError.contains("已删除"))) {
        break;
      }
      await Future.delayed(const Duration(seconds: 3));
    }

    throw Exception(lastError ?? "Failed to get chapters");
  }

  /// 取一话的图片列表, 失败只记账不外抛 —— 否则整本下载会失败,
  /// start() 走 catch 分支反复 retry, 连能下的那几话也一起卡在「获取图片信息」。
  /// 取不到的话在 links 里占一个空列表: 主循环会跳过它, 但话的位置不会错位。
  Future<void> _fetchOneEp(int i, Map<int, List<String>> links) async {
    if (links[i + 1] != null) return;
    try {
      await getOneEp(i, links);
    } catch (e) {
      skippedEps.add(i);
      links[i + 1] = [];
      LogManager.addLog(
          LogLevel.warning, "Download", "跳过第 ${i + 1} 话(取不到图片): $e");
    }
  }

  /// 懒加载: 只取这一话的图片地址。
  ///
  /// 以前是开下载就把全书地址一次取完, 而再漫画的图片地址带签名有效期,
  /// 隔天继续下载时那批地址早就失效了, 一张都下不动。改成用到哪话取哪话。
  @override
  Future<int> ensureEpLinks(int position) async {
    if (comic.chapters == null) {
      return super.ensureEpLinks(position);
    }
    links ??= <int, List<String>>{};
    var i = _downloadEps[position];
    if (links![i + 1] == null) {
      await _fetchOneEp(i, links!);
      linkDone = position + 1;
      linkTotal = _downloadEps.length;
      updateInfo?.call();
    }
    return i + 1;
  }

  @override
  Future<Map<int, List<String>>> getLinks() async {
    if (comic.chapters == null || _downloadEps.isEmpty) {
      if (comic.chapters == null) {
        return {0: (await source.loadComicPages!(comic.comicId, null)).data};
      }
      return {};
    }
    /// 只取第一话, 其余等下载到那一话时再取(见 ensureEpLinks)。
    /// 断点续传时从当前进度直接开始, 不必回头取第一话。
    linkTotal = _downloadEps.length;
    linkDone = 0;
    skippedEps.clear();
    if (_downloadingEp > 0) {
      return {};
    }
    var result = <int, List<String>>{};
    await _fetchOneEp(_downloadEps.first, result);
    linkDone = 1;
    updateInfo?.call();
    /// 只选了一话又取不到图片时直接报错(让用户看到原因);
    /// 选多话时第一话取不到(常见于排在最前的"卷")只是跳过, 继续下后面的。
    if (_downloadEps.length == 1 &&
        (result[_downloadEps.first + 1]?.isEmpty ?? true)) {
      throw Exception("第 ${_downloadEps.first + 1} 话取不到图片");
    }
    return result;
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

  /// 已下完的话(0-based 话序号), 按完成顺序。
  ///
  /// 不能再用 "links.keys.take(downloadingEp)" 推断: 懒加载 + 地址失效重取之后,
  /// links 里未必还留着前面几话的 key, 那样推断会错位、把没下的话标成可读。
  final List<int> _doneEps = [];

  @override
  Future<void> onEpisodeDownloaded(int ep) async {
    if (directory == null) return;
    /// links 的 key 是 1-based 话序号; 取不到图片的话(空列表)不算下完。
    /// 没有章节概念的源只有一个 key 0, 对应的话序号就是 0。
    var epIndex = comic.chapters == null ? 0 : ep - 1;
    if ((links?[ep]?.isEmpty ?? true) || skippedEps.contains(epIndex)) {
      return;
    }
    if (!_doneEps.contains(epIndex)) {
      _doneEps.add(epIndex);
    }

    /// 只扫这一话新增的目录并累加, 让「已下载」里显示的是真实体积而不是 0.00MB
    for (var i = _sizedEps; i < _doneEps.length; i++) {
      var epDir = Directory("$path/${_doneEps[i] + 1}");
      if (epDir.existsSync()) {
        _knownSize += await getFolderSize(epDir);
      }
    }
    _sizedEps = _doneEps.length;

    if (_doneEps.length == _syncedEps) return;
    /// 「已下载」区域只在第一话下完时刷一次, 后面各话只更新数据库不刷页面,
    /// 免得用户正在看的列表反复跳动(整本下完时 onTaskFinished 会再刷一次)。
    var firstEpisode = _syncedEps == 0;
    _syncedEps = _doneEps.length;
    DownloadManager().addPartiallyDownloaded(
        await _buildDownloadedItem(_doneEps, size: _knownSize), directory!,
        refresh: firstEpisode);
  }

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    return _getImage(link);
  }
}
