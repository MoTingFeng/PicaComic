import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/get_gallery_id.dart';
import 'package:pica_comic/network/favorite_download.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_download_model.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/htmanga_network/ht_download_model.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/pages/download_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/sqlite3.dart';

import 'nhentai_network/models.dart';
import 'picacg_network/models.dart';

typedef DownloadingCallback = void Function();

class DownloadManager with _DownloadDb implements Listenable {
  static DownloadManager? cache;

  factory DownloadManager() => cache ?? (cache = DownloadManager._create());

  DownloadManager._create();

  ///下载目录
  String? path;

  ///下载队列
  var downloading = Queue<DownloadingItem>();

  ///是否正在下载
  bool isDownloading = false;

  ///是否出现了错误
  bool _error = false;

  ///是否出现了错误
  bool get error => _error;

  ///是否初始化
  bool _runInit = false;

  @override
  Database? _db;

  final List<VoidCallback> _listeners = [];

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void notifyListeners() {
    for (var listener in _listeners) {
      listener();
    }
  }

  ///获取下载目录
  Future<void> _getPath() async {
    if (appdata.settings[22] == "") {
      final appPath = await getApplicationSupportDirectory();
      path = "${appPath.path}/download";
    } else {
      path = appdata.settings[22];
    }
    if (App.isIOS) {
      if (path!.startsWith('/var/mobile/Containers/Data/Application/')) {
        if (!Directory(path!).existsSync()) {
          final appPath = await getApplicationSupportDirectory();
          path = "${appPath.path}/download";
        }
      }
    }
    var dir = Directory(path!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    if (App.isAndroid) {
      var file = File("$path/.nomedia");
      if (!file.existsSync()) {
        await file.create();
      }
    }
  }

  ///更换下载目录
  Future<String> updatePath(String newPath, {bool transform = true}) async {
    if (transform) {
      var source = Directory(path!);
      final appPath = await getApplicationSupportDirectory();
      var destination = Directory(
        newPath == "" ? "${appPath.path}${pathSep}download" : newPath,
      );
      try {
        await copyDirectory(source, destination);
        for (var i in source.listSync()) {
          await i.delete(recursive: true);
        }
      } catch (e) {
        return e.toString();
      }
    }

    _runInit = false;
    _db!.dispose();
    downloading.clear();
    await init();
    return "ok";
  }

  ///读取数据, 获取未完成的下载和已下载的漫画ID
  Future<void> _getInfo() async {
    //读取数据
    var file = File("$path${pathSep}newDownload.json");
    if (!file.existsSync()) {
      await _saveInfo();
    } else {
      try {
        var json = const JsonDecoder().convert(file.readAsStringSync());
        for (var item in json["downloading"]) {
          downloading.add(
              downloadingItemFromMap(item, _onFinish, _onError, _saveInfo));
        }
      } catch (e, s) {
        LogManager.addLog(LogLevel.error, "IO",
            "Failed to read downloaded information\n$e\n$s");
        file.deleteSync();
        await _saveInfo();
      }
    }
  }

  Future<void> _initDb() async {
    var oldData = <String, DownloadedItem>{};
    if (!File("$path/download.db").existsSync()) {
      for (var entry in Directory(path!).listSync()) {
        if (entry is Directory) {
          var infoFile = File("${entry.path}/info.json");
          if (infoFile.existsSync()) {
            var id = entry.name;
            var json = infoFile.readAsStringSync();
            var time = infoFile.lastModifiedSync();
            var comic = _getComicFromJson(id, json, time);
            if (comic != null) {
              infoFile.delete();
              var directory = comic.name;
              int i = -1;
              while (entry is Directory) {
                try {
                  entry = entry.renameX(directory);
                  break;
                } catch (e) {
                  i++;
                  if(i > 20) {
                    // it seems that the error is unrelated to the directory name
                    Log.error("IO", "Failed to rename directory: Trying rename ${entry.name} to ${comic.name}\n$e");
                    break;
                  }
                  directory = comic.name + i.toString();
                }
              }
              oldData[entry.name] = comic;
            }
          }
        }
      }
    }
    _db = sqlite3.open("$path/download.db");
    _createTable();
    for (var entry in oldData.entries) {
      _addToDb(entry.value, entry.key);
    }
  }

  void dispose() {
    _runInit = false;
    downloading.forEach((e) => e.stop());
    downloading.clear();
    _db?.dispose();
    _db = null;
  }

  ///初始化下载管理器
  Future<void> init() async {
    if (_runInit) return;
    _runInit = true;
    await _getPath();
    await _getInfo();
    await _initDb();
  }

  ///储存当前的下载队列信息, 每完成一张图片的下载调用一次
  Future<void> _saveInfo() async {
    notifyListeners();
    var data = <String, dynamic>{};
    data["downloading"] = <Map<String, dynamic>>[];
    for (var item in downloading) {
      data["downloading"].add(item.toMap());
    }
    var file = File("$path${pathSep}newDownload.json");
    await file.writeAsString(const JsonEncoder().convert(data));
  }

  /// 每个漫画源当前正在下载的任务: sourceKey -> 任务 id。
  /// 同一个源同时只跑一个任务(避免同源并发被风控), 不同源之间并行。
  final Map<String, String> _activeTasks = {};

  /// 该任务是否是它所在源当前的活动任务
  bool isActive(DownloadingItem item) => _activeTasks[item.sourceKey] == item.id;

  /// 启动任务并占住它所在源的槽
  void _startTask(DownloadingItem item) {
    _activeTasks[item.sourceKey] = item.id;
    item.start();
  }

  /// 该任务所在源空闲时才启动它
  void _startIfIdle(DownloadingItem item) {
    if (_activeTasks.containsKey(item.sourceKey)) return;
    _startTask(item);
  }

  /// 释放任务占用的源槽
  void _releaseTask(DownloadingItem item) {
    if (_activeTasks[item.sourceKey] == item.id) {
      _activeTasks.remove(item.sourceKey);
    }
  }

  /// 给每个空闲的源各启动一个任务(按队列顺序, 同源只取最早的那个)。
  /// 先全部占槽再逐个启动: start() 内部可能改动队列, 不能在遍历中直接调。
  void _startIdleTasks() {
    var pending = <DownloadingItem>[];
    for (var item in downloading) {
      if (_activeTasks.containsKey(item.sourceKey)) continue;
      _activeTasks[item.sourceKey] = item.id;
      pending.add(item);
    }
    for (var item in pending) {
      item.start();
    }
  }

  /// move comic to first
  ///
  /// 并发下载时不再为此暂停其它源的任务, 只保证该源的下一个名额归它。
  void moveToFirst(DownloadingItem item) {
    if (downloading.first == item) {
      return;
    }
    downloading.remove(item);
    downloading.addFirst(item);
    if (!isActive(item)) {
      //置顶视为继续下载: 暂停状态下也能靠它把本源跑起来
      isDownloading = true;
      _startIfIdle(item);
    }
    notifyListeners();
  }

  String generateId(String source, String id) {
    var comicSource = ComicSource.find(source)!;
    if (comicSource.matchBriefIdReg != null) {
      id = RegExp(comicSource.matchBriefIdReg!).firstMatch(id)!.group(1)!;
    }
    id = "$source-$id";
    return id;
  }

  ///分话下载的任务每下完一话调用一次: 立刻把这本书写进「已下载」列表,
  ///这样用户不必等整本下完就能看到它、并阅读已经下完的话。
  ///
  ///[refresh] 是否让「已下载」页面立刻刷新 —— 只在第一话写入时为 true,
  ///后面每话都刷会让用户正在看的列表反复跳动。
  Future<void> addPartiallyDownloaded(
      DownloadedItem item, String directory, {bool refresh = true}) async {
    _addToDb(item, directory);
    await _saveInfo();
    if (refresh) {
      StateController.findOrNull<DownloadPageLogic>()?.refresh();
    }
  }

  /// 历史完成回调。
  ///
  /// 完成通知已由 [onTaskFinished] 接管 —— 那个版本带着任务身份, 并发下载时
  /// 才能知道是哪一本下完了。这里保留空实现, 只为不改动各源的构造签名。
  void _onFinish() {}

  /// 当一个下载任务完成时, 由 DownloadingItem.notifyDownloadFinished() 调用。
  /// 必须带上任务本身: 并发下载时完成的未必是队首。
  Future<void> onTaskFinished(DownloadingItem task) async {
    downloading.remove(task);
    _releaseTask(task);
    _addToDb(await task.toDownloadedItem(), task.directory!);
    await _saveInfo();
    StateController.findOrNull<DownloadPageLogic>()?.refresh();
    //清除已完成的任务, 给空闲的源安排下一个任务
    _startIdleTasks();
    if (_activeTasks.isEmpty) {
      //标记状态为未在下载
      isDownloading = false;
      notifications.endProgress();
    }
  }

  /// 用解析完成的真实任务替换占位任务(见 FavoriteDownloading):
  /// 占位任务本身不下载图片, 只是先解析出真实的下载任务。
  void replaceTask(DownloadingItem old, DownloadingItem replacement) {
    downloading.remove(old);
    _releaseTask(old);
    if (!downloading.any((e) => e.id == replacement.id)) {
      downloading.addFirst(replacement);
    }
    isDownloading = true;
    _startIfIdle(replacement);
    notifyListeners();
    _saveInfo();
  }

  /// 按 id 在下载队列里找任务。
  /// 不用 firstWhereOrNull: 那个扩展只对 List 定义, Queue 上用不了。
  DownloadingItem? _findTask(String id) {
    for (var item in downloading) {
      if (item.id == id) return item;
    }
    return null;
  }

  ///暂停下载(所有源的活动任务)
  void pause() {
    isDownloading = false;
    for (var id in _activeTasks.values.toList()) {
      _findTask(id)?.pause();
    }
    _activeTasks.clear();
  }

  ///出现错误时调用此函数
  void _onError() {
    pause();
    _error = true;
    notifications.sendNotification("下载出错".tl, "点击查看详情".tl);
    notifyListeners();
  }

  ///开始或继续下载
  void start() {
    _error = false;
    isDownloading = true;
    _startIdleTasks();
  }

  ///取消指定的下载
  void cancel(String id) {
    var item = _findTask(id);
    if (item == null) return;

    item.stop();
    downloading.remove(item);
    _releaseTask(item);

    notifyListeners();

    if (downloading.isEmpty) {
      isDownloading = false;
      notifications.endProgress();
    } else {
      _startIdleTasks();
    }
    _saveInfo();
  }

  Future<DownloadedItem?> getComicOrNull(String id) async {
    return _getComicWithDb(id);
  }

  ///删除已下载的漫画
  Future<void> delete(List<String> ids) async {
    for (var id in ids) {
      _deleteFromDb(id);
      var comic = Directory("$path/${getDirectory(id)}");
      try {
        comic.delete(recursive: true);
      } catch (e) {
        if (e is PathNotFoundException) {
          //忽略
        } else {
          rethrow;
        }
      }
    }
  }

  /// return error message when error, or null if success.
  Future<String?> deleteEpisode(DownloadedItem comic, int ep) async {
    try {
      if (comic.downloadedEps.length == 1) {
        return "Delete Error: only one downloaded episode";
      }
      if (Directory("$path/${getDirectory(comic.id)}/${ep + 1}").existsSync()) {
        Directory("$path/${getDirectory(comic.id)}/${ep + 1}")
            .deleteSync(recursive: true);
      }
      var size = Directory("$path/${getDirectory(comic.id)}").getMBSizeSync();
      comic.downloadedEps.remove(ep);
      comic.comicSize = size;
      _addToDb(comic, comic.directory ?? getDirectory(comic.id));
      return null;
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "IO", "$e/n$s");
      return e.toString();
    }
  }

  /// 获取漫画章节的长度, 适用于有章节的漫画
  Future<int> getEpLength(String id, int ep) async {
    var directory = Directory("$path/${getDirectory(id)}/$ep");
    var files = directory.list();
    return files.length;
  }

  /// 获取漫画的长度, 适用于无章节的漫画
  Future<int> getComicLength(String id) async {
    var directory = Directory("$path/${getDirectory(id)}");
    var files = directory.list();
    return await files.length - 1;
  }

  ///获取图片, 对于无章节的漫画, ep参数为0
  File getImage(String id, int ep, int index) {
    String downloadPath;
    if (ep == 0) {
      downloadPath = "$path/${getDirectory(id)}/";
    } else {
      downloadPath = "$path/${getDirectory(id)}/$ep/";
    }
    for (var file in Directory(downloadPath).listSync()) {
      if (file.uri.pathSegments.last.replaceFirst(RegExp(r"\..+"), "") ==
          index.toString()) {
        return file as File;
      }
    }
    throw Exception("File not found");
  }

  Future<File> getImageAsync(String id, int ep, int index) async {
    String downloadPath;
    if (ep == 0) {
      downloadPath = "$path/${getDirectory(id)}/";
    } else {
      downloadPath = "$path/${getDirectory(id)}/$ep/";
    }
    var fileName  = _downloadedFileName["$id$ep$index"];
    if(fileName != null) {
      return File(downloadPath + fileName);
    }
    await for (var file in Directory(downloadPath).list()) {
      var i = file.uri.pathSegments.last.replaceFirst(RegExp(r"\..+"), "");
      if(i.isNum) {
        if(_downloadedFileName.length > 2000) {
          _downloadedFileName.remove(_downloadedFileName.keys.first);
        }
        _downloadedFileName["$id$ep$i"] = file.name;
      }
    }
    if(_downloadedFileName["$id$ep$index"] == null) {
      throw Exception("File not found");
    }
    return File(downloadPath + _downloadedFileName["$id$ep$index"]!);
  }

  static final _downloadedFileName = <String, String>{};

  ///获取封面, 所有漫画源通用
  File getCover(String id) {
    return File("$path/${getDirectory(id)}/cover.jpg");
  }
}

DownloadingItem downloadingItemFromMap(
    Map<String, dynamic> map,
    void Function() whenFinish,
    void Function() whenError,
    Future<void> Function() updateInfo) {
  switch (map["type"]) {
    case 0:
      return PicDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 1:
      return EhDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 2:
      return JmDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 3:
      return HitomiDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 4:
      return DownloadingHtComic.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 5:
      return NhentaiDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 6:
      return CustomDownloadingItem.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    case 7:
      return FavoriteDownloading.fromMap(
          map, whenFinish, whenError, updateInfo, map["id"]);
    default:
      throw UnimplementedError();
  }
}

/// 从已下载记录反推「继续下载 / 重新下载」所需的源标识与原始标识。
///
/// 各源的下载 id 规则不同(见 [DownloadedItem.id]), 这里统一还原,
/// 供下载页的长按菜单使用。hitomi 与 e-hentai 的原始链接存在记录内部,
/// 需要靠类型判断取回。
extension DownloadedItemExt on DownloadedItem {
  /// 该记录所属的漫画源 key; 无法判断时为 null
  String? get sourceKey {
    switch (type) {
      case DownloadType.picacg:
        return 'picacg';
      case DownloadType.ehentai:
        return 'ehentai';
      case DownloadType.jm:
        return 'jm';
      case DownloadType.hitomi:
        return 'hitomi';
      case DownloadType.htmanga:
        return 'htmanga';
      case DownloadType.nhentai:
        return 'nhentai';
      default:
        // 自定义源: id 形如 "<sourceKey>-<comicId>"
        var i = id.indexOf('-');
        return i > 0 ? id.substring(0, i) : null;
    }
  }

  /// 传给源接口的原始标识; 无法还原时为 null
  String? get reDownloadTarget {
    switch (type) {
      case DownloadType.picacg:
        return id;
      case DownloadType.ehentai:
        return this is DownloadedGallery
            ? (this as DownloadedGallery).gallery.link
            : null;
      case DownloadType.jm:
        return id.startsWith('jm') ? id.substring(2) : null;
      case DownloadType.hitomi:
        return this is DownloadedHitomiComic
            ? (this as DownloadedHitomiComic).link
            : null;
      case DownloadType.htmanga:
        return id.startsWith('Ht') ? id.substring(2) : null;
      case DownloadType.nhentai:
        return id.startsWith('nhentai') ? id.substring(7) : null;
      default:
        var i = id.indexOf('-');
        return i > 0 ? id.substring(i + 1) : null;
    }
  }
}

extension AddDownloadExt on DownloadManager {
  /// 统一入队: 同一漫画(同 id)不重复添加, 防止重复下载与下载页出现重复任务
  void _enqueueDownload(DownloadingItem item) {
    if (downloading.any((e) => e.id == item.id)) {
      return;
    }
    downloading.addLast(item);
    _saveInfo();
    isDownloading = true;
    //该源空闲时才真的开跑: 同源仍按队列串行, 不同源并行
    _startIfIdle(item);
  }

  ///添加哔咔漫画下载
  void addPicDownload(ComicItem comic, List<int> downloadEps) {
    _enqueueDownload(PicDownloadingItem(
        comic, downloadEps, _onFinish, _onError, _saveInfo, comic.id));
  }

  ///添加E-Hentai下载
  void addEhDownload(Gallery gallery, [int type = 0]) {
    final id = getGalleryId(gallery.link);
    _enqueueDownload(
        EhDownloadingItem(gallery, _onFinish, _onError, _saveInfo, id, type));
  }

  ///添加禁漫下载
  void addJmDownload(JmComicInfo comic, List<int> downloadEps) {
    _enqueueDownload(JmDownloadingItem(
        comic, downloadEps, _onFinish, _onError, _saveInfo, "jm${comic.id}"));
  }

  ///添加Hitomi下载
  void addHitomiDownload(HitomiComic comic, String cover, String link) {
    final id = "hitomi${comic.id}";
    _enqueueDownload(HitomiDownloadingItem(
        comic, cover, link, _onFinish, _onError, _saveInfo, id));
  }

  ///添加绅士漫画下载
  void addHtDownload(HtComicInfo comic) {
    final id = "Ht${comic.id}";
    _enqueueDownload(
        DownloadingHtComic(comic, _onFinish, _onError, _saveInfo, id));
  }

  void addNhentaiDownload(NhentaiComic comic) {
    final id = "nhentai${comic.id}";
    _enqueueDownload(
        NhentaiDownloadingItem(comic, _onFinish, _onError, _saveInfo, id));
  }

  void addCustomDownload(ComicInfoData comic, List<int> downloadEps) {
    var id = generateId(comic.sourceKey, comic.comicId);
    _enqueueDownload(CustomDownloadingItem(
        comic, downloadEps, _onFinish, _onError, _saveInfo, id));
  }

  void addFavoriteDownload(FavoriteItem comic) {
    var id = switch (comic.type.key) {
      0 => comic.target,
      1 => getGalleryId(comic.target),
      2 => "jm${comic.target}",
      3 => "hitomi${RegExp(r"\d+(?=\.html)").firstMatch(comic.target)![0]!}",
      4 => "Ht${comic.target}",
      6 => "nhentai${comic.target}",
      _ => generateId(comic.type.comicSource.key, comic.target)
    };
    _enqueueDownload(
        FavoriteDownloading(comic, _onFinish, _onError, _saveInfo, id));
  }
}

DownloadedItem? _getComicFromJson(String id, String json, DateTime time, [String? directory]) {
  DownloadedItem comic;
  try {
    if (id.contains('-')) {
      comic = CustomDownloadedItem.fromJson(jsonDecode(json));
    } else if (id.startsWith("jm")) {
      comic = DownloadedJmComic.fromMap(jsonDecode(json));
    } else if (id.startsWith("hitomi")) {
      comic = DownloadedHitomiComic.fromMap(jsonDecode(json));
    } else if (id.startsWith("nhentai")) {
      comic = NhentaiDownloadedComic.fromJson(jsonDecode(json));
    } else if (id.startsWith("Ht")) {
      comic = DownloadedHtComic.fromJson(jsonDecode(json));
    } else if (id.isNum) {
      comic = DownloadedGallery.fromJson(jsonDecode(json));
    } else {
      comic = DownloadedComic.fromJson(jsonDecode(json));
    }
    comic.time = time;
    comic.directory = directory;
    return comic;
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "IO", "Failed to get a downloaded comic info:\n$e\n$s");
    return null;
  }
}

abstract mixin class _DownloadDb {
  Database? get _db;

  void _createTable() {
    _db!.execute('''
      create table if not exists download (
        id text primary key,
        title text,
        subtitle text,
        time int,
        directory text,
        size int,
        json text
      )
    ''');
  }

  void _addToDb(DownloadedItem item, String directory, [DateTime? time]) {
    _db!.execute('''
      insert or replace into download
      values (?,?,?,?,?,?,?)
    ''', [
      item.id,
      item.name,
      item.subTitle,
      (time ?? DateTime.now()).millisecondsSinceEpoch,
      directory,
      item.comicSize,
      jsonEncode(item.toJson()),
    ]);
  }

  bool isExists(String id) {
    var result = _db!.select('''
      select id from download
      where id = ?
    ''', [id]);
    return result.isNotEmpty;
  }

  void _deleteFromDb(String id) {
    _db!.execute('''
      delete from download
      where id = ?
    ''', [id]);
  }

  DownloadedItem? _getComicWithDb(String id) {
    var result = _db!.select('''
      select * from download
      where id = ?
    ''', [id]);
    if (result.isEmpty) return null;
    var data = result.first;
    return _getComicFromJson(
      data['id'],
      data['json'],
      DateTime.fromMillisecondsSinceEpoch(data['time']),
      data['directory'],
    );
  }

  int get total {
    var result = _db!.select('''
      select count(*) from download
    ''');
    return result.first['count(*)'];
  }

  /// order: time, title, subtitle, size
  List<DownloadedItem> getAll(
      [String order = 'time', String direction = 'desc']) {
    var result = _db!.select('''
      select * from download
      order by $order $direction
    ''');
    var list = <DownloadedItem>[];
    for (var row in result) {
      // 单条记录损坏不能让整个下载页白屏:
      // 解析失败就丢弃该条, 并清理它残留的磁盘目录与数据库条目
      var id = row['id'];
      try {
        var item = _getComicFromJson(
          id as String,
          row['json'] as String,
          DateTime.fromMillisecondsSinceEpoch(row['time'] as int),
          row['directory'] is String ? row['directory'] as String : null,
        );
        if (item != null) {
          list.add(item);
        } else {
          _discardBrokenDownload(id, row['directory']);
        }
      } catch (e) {
        if (id is String) {
          _discardBrokenDownload(id, null);
        }
      }
    }
    return list;
  }

  /// 丢弃一条无法解析的下载记录: 先删磁盘目录, 再删数据库条目
  void _discardBrokenDownload(String id, dynamic directory) {
    if (directory is String && directory.isNotEmpty) {
      try {
        var dir = Directory("${DownloadManager().path}/$directory");
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      } catch (_) {
        // 目录已不存在或无法删除, 忽略
      }
    }
    try {
      _deleteFromDb(id);
    } catch (e) {
      LogManager.addLog(
          LogLevel.error, "IO", "Failed to remove broken download record: $e");
    }
  }

  static final _cache = <String, String>{};

  String getDirectory(String id) {
    var directory = _cache[id];
    if(directory == null) {
      var result = _db!.select('''
      select directory from download
      where id = ?
    ''', [id]);
      directory = result.first['directory'];
      directory = _findAccurateDirectory(directory!);
      if(_cache.length > 50) {
        _cache.remove(_cache.keys.first);
      }
      _cache[id] = directory;
    }
    return directory;
  }

  String _findAccurateDirectory(String directory) {
    return sanitizeFileName(directory);
  }
}
