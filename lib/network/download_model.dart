import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/file_type.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/translations.dart';

import '../base.dart';
import 'app_dio.dart';
import 'download.dart';

abstract class DownloadedItem {
  ///漫画源
  DownloadType get type;

  ///漫画名
  String get name;

  ///章节
  List<String> get eps;

  ///已下载的章节
  List<int> get downloadedEps;

  ///标识符
  String get id;

  ///副标题, 通常为作者
  String get subTitle;

  ///大小
  double? get comicSize;

  ///下载的时间
  DateTime? time;

  /// tags
  List<String> get tags;

  Map<String, dynamic> toJson();

  set comicSize(double? value);

  String? directory;
}

enum DownloadType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htmanga,
  nhentai,
  other,
  favorite;

  ComicType toComicType() => switch (this) {
        picacg => ComicType.picacg,
        ehentai => ComicType.ehentai,
        jm => ComicType.jm,
        hitomi => ComicType.hitomi,
        htmanga => ComicType.htManga,
        nhentai => ComicType.nhentai,
        other => ComicType.other,
        favorite => ComicType.other,
      };
}

typedef DownloadProgressCallback = void Function();

typedef DownloadProgressCallbackAsync = Future<void> Function();

abstract class DownloadingItem with _TransferSpeedMixin {
  ///完成时调用。
  ///
  /// 已由 [notifyDownloadFinished] 取代 —— 这个回调没有参数, 并发下载时
  /// DownloadManager 分辨不出是哪个任务结束了。保留字段只为不改构造签名。
  final DownloadProgressCallback? onFinish;

  ///出现错误时调用
  final DownloadProgressCallback? onError;

  ///更新下载信息
  final DownloadProgressCallbackAsync? updateInfo;

  ///标识符, 对于哔咔和eh, 直接使用其提供的漫画id, 禁漫开头加jm, hitomi开头加hitomi
  final String id;

  ///类型
  DownloadType type;

  /// 任务所属的漫画源标识。并发调度按它分组: 同源串行、不同源并行。
  /// 内置源按类型区分; JS 源(都是 other)各自覆写为真实的 sourceKey。
  String get sourceKey => type.name;

  /// run function start will cause this increasing by 1
  ///
  /// this is used for preventing running multiple downloading function at the same time
  int _runtimeKey = 0;

  int _retryTimes = 0;

  String? directory;

  String get path {
    var downloadPath = DownloadManager().path!;
    return "$downloadPath/$directory";
  }

  /// headers for downloading cover
  Map<String, String> get headers => {};

  int _downloadedNum = 0;

  int _downloadingEp = 0;

  /// index of downloading episode
  ///
  /// Attention, this is used for array indexing, so it starts with 0
  int get downloadingEp => _downloadingEp;

  int index = 0;

  /// all image urls
  Map<int, List<String>>? links;

  /// 「获取图片信息」阶段(逐话取图片列表)的进度: 已完成话数 / 本次总话数。
  /// 只有分话下载的源会填; 保持 null 时界面按原来的单一文案显示。
  int? linkDone;

  int? linkTotal;

  int get allowedLoadingNumber => int.tryParse(appdata.settings[79]) ?? 6;

  DownloadingItem(this.onFinish, this.onError, this.updateInfo, this.id,
      {required this.type});

  Future<void> downloadCover() async {
    var file = File("$path/cover.jpg");
    if (file.existsSync()) {
      return;
    }
    var dio = logDio();
    var res = await dio.get<Uint8List>(cover,
        options: Options(responseType: ResponseType.bytes, headers: headers));
    if (file.existsSync()) {
      file.deleteSync();
    }
    file.createSync(recursive: true);
    file.writeAsBytesSync(res.data!);
  }

  /// retry when error
  Future<void> retry() async {
    _retryTimes++;
    if (_retryTimes > 4) {
      onError?.call();
      _retryTimes = 0;
    } else {
      /// 每一次任务级重试都给单张图重新计次数, 否则第一轮用光额度后
      /// 后面几轮会立刻放弃, 白白浪费重试机会
      _imageRetryTimes.clear();
      await Future.delayed(Duration(seconds: 2 << _retryTimes));
      start();
    }
  }

  @mustCallSuper
  FutureOr<void> onStart() {
    if (directory == null) {
      if(DownloadManager().isExists(id)) {
        directory = DownloadManager().getDirectory(id);
      } else {
      directory = findValidDirectoryName(DownloadManager().path!, title);
      Directory(path).createSync(recursive: true);
      }
    }
  }

  final _downloading = <String, _ImageDownloadWrapper>{};

  /// 同一张图的连续失败次数。图片地址失效时源站会一直拒,
  /// 不设上限的话"失败→重建任务→再失败"会原地打转(日志刷屏, 任务永远不推进)。
  final _imageRetryTimes = <String, int>{};

  /// 单张图最多重试几次, 超过就停下来把错误交给任务级处理
  static const _maxImageRetry = 3;

  void _addDownloading(String link, int ep, int index) {
    var downloadTo = '';
    var basename = '';
    if (haveEps) {
      downloadTo = "$path/$ep";
      basename = index.toString();
    } else {
      downloadTo = path;
      basename = index.toString();
    }
    if (_downloading["$ep$index"] == null ||
        _downloading["$ep$index"]!.error != null) {
      var taskKey = "$ep$index";
      _downloading[taskKey] = _ImageDownloadWrapper(
        downloadImage(link),
        downloadTo,
        basename,
        onData,
        () {
          updateInfo?.call();
          if (_downloading[taskKey]?.error != null) {
            /// 4xx 说明地址本身不可用(多半是带签名的地址过期了), 原地重试没意义,
            /// 直接停下来交给任务级重取地址
            if (_isStaleLinkError(_downloading[taskKey]!.error!)) {
              return;
            }
            var times = (_imageRetryTimes[taskKey] ?? 0) + 1;
            _imageRetryTimes[taskKey] = times;
            if (times > _maxImageRetry) {
              /// 放弃原地重试, 等待中的 start() 会拿到这个错误并走任务级重试
              return;
            }
            Future.delayed(Duration(milliseconds: 300 * times), () {
              _scheduleTasks(ep, this.index);
            });
            return;
          }
          _imageRetryTimes.remove(taskKey);
          _scheduleTasks(ep, this.index);
        },
      );
    }
  }

  void _scheduleTasks(int ep, int index) {
    var urls = links![ep]!;
    int downloading = 0;
    for (int i = index; i < urls.length; i++) {
      var task = _downloading["$ep$i"];
      if (task == null || task.error != null) {
        _addDownloading(urls[i], ep, i);
        downloading++;
      } else if (!task.isFinished) {
        downloading++;
      }
      if (downloading >= allowedLoadingNumber) {
        break;
      }
    }
  }

  /// begin or continue downloading
  void start() async {
    _runtimeKey++;
    var currentKey = _runtimeKey;
    try {
      await onStart();
      if (_runtimeKey != currentKey) return;
      notifications.sendProgressNotification(downloadedPages, totalPages,
          "下载中".tl, "${downloadManager.downloading.length} Tasks");

      // get image links and cover
      links ??= await getLinks();
      await downloadCover();
      runRecorder();

      // download images
      while (_downloadingEp < totalEps && currentKey == _runtimeKey) {
        /// 懒加载: 按需取这一话的图片地址, 不再开下载就先预取全书地址
        int ep = await ensureEpLinks(_downloadingEp);
        if (currentKey != _runtimeKey) return;
        var urls = links![ep]!;
        while (index < urls.length && currentKey == _runtimeKey) {
          notifications.sendProgressNotification(downloadedPages, totalPages,
              "下载中".tl, "${downloadManager.downloading.length} Tasks");
          _scheduleTasks(ep, index);
          if (currentKey != _runtimeKey) return;
          var task = _downloading["$ep$index"];
          if (task == null) {
            throw Exception("Task not started");
          }
          await task.wait();
          if (task.error != null) {
            throw task.error!;
          }
          if (!task.isFinished) {
            throw Exception("Task not finished");
          }
          _downloading.remove("$ep$index");
          _imageRetryTimes.remove("$ep$index");
          index++;
          _downloadedNum++;
          await updateInfo?.call();
        }
        if (currentKey != _runtimeKey) return;
        index = 0;
        _downloadingEp++;
        /// 让「已下载」列表立刻能看到这本书, 不必等整本下完
        await onEpisodeDownloaded(ep);
        await updateInfo?.call();
      }

      // finish downloading
      if (!DownloadManager().isActive(this)) return;
      _staleLinkRefresh = 0;
      notifyDownloadFinished();
      _stopAllTasks();
    } catch (e, s) {
      if (currentKey != _runtimeKey) return;
      LogManager.addLog(LogLevel.error, "Download", "$e\n$s");
      if (_isStaleLinkError(e)) {
        /// 图片地址带签名有效期时(再漫画的 images 域名就是), 隔天继续下载
        /// 用的还是昨天那批地址, 源站一律 4xx。这种情况必须重新取地址 ——
        /// 拿同一批失效链接重试多少次都是白搭。
        /// 配合懒加载, 重取只花"当前这一话"的请求, 不是整本重来。
        _staleLinkRefresh++;
        if (_staleLinkRefresh > 3) {
          _staleLinkRefresh = 0;
          LogManager.addLog(LogLevel.error, "Download",
              "图片地址重取 3 次后仍被拒, 该漫画可能需要在源站重新登录或有阅读权限限制");
          onError?.call();
          return;
        }
        LogManager.addLog(LogLevel.warning, "Download",
            "图片地址已失效(第 $_staleLinkRefresh 次重取), 重新获取本话及之后的地址");
        links = null;
        _downloading.clear();
        _imageRetryTimes.clear();
        linkDone = null;
        linkTotal = null;
        start();
        return;
      }
      retry();
    }
  }

  /// 图片地址失效后已经重取过几次
  int _staleLinkRefresh = 0;

  /// 这个错误是否说明"图片地址不可用"(源站对图片返回了 4xx)
  bool _isStaleLinkError(Object e) {
    if (e is BadRequestException) return true;
    if (e is DioException) {
      var code = e.response?.statusCode;
      return code != null && code >= 400 && code < 500;
    }
    return false;
  }

  void _stopAllTasks() {
    var shouldRemove = <String>[];
    for(var entry in _downloading.entries) {
      if(!entry.value.isFinished) {
        entry.value.cancel();
        shouldRemove.add(entry.key);
      }
    }
    for(var key in shouldRemove) {
      _downloading.remove(key);
    }
  }

  /// pause downloading
  void pause() {
    _runtimeKey++;
    stopRecorder();
    notifications.endProgress();
    _stopAllTasks();
    ImageManager.clearTasks();
  }

  /// stop downloading
  void stop() {
    _runtimeKey++;
    stopRecorder();
    _stopAllTasks();
    notifications.endProgress();
    if (downloadManager.isExists(id)) {
      if (links == null) return;
      var comicPath = "$path/";
      for (var ep in links!.keys.toList()) {
        var directory = Directory(comicPath + ep.toString());
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      }
    } else {
      var file = Directory(path);
      if (file.existsSync()) {
        file.delete(recursive: true);
      }
    }
  }

  Map<String, dynamic> toBaseMap() {
    Map<String, List<String>>? convertedData;
    if (links != null) {
      convertedData = {};
      links!.forEach((key, value) {
        convertedData![key.toString()] = value;
      });
    }

    return {
      "id": id,
      "type": type.index,
      "_downloadedNum": _downloadedNum,
      "_downloadingEp": _downloadingEp,
      "index": index,
      "links": convertedData,
      "directory": directory,
      "finishedTasks": _downloading.entries
          .where((element) => element.value.isFinished)
          .map((e) => e.key)
          .toList(),
    };
  }

  Map<String, dynamic> toMap();

  DownloadingItem.fromMap(
      Map<String, dynamic> map, this.onFinish, this.onError, this.updateInfo)
      : id = map["id"],
        type = DownloadType.values[map["type"]],
        _downloadedNum = map["_downloadedNum"],
        _downloadingEp = map["_downloadingEp"],
        index = map["index"],
        links = null {
    var data = map["links"] as Map<String, dynamic>?;
    if (data != null) {
      links = {};
      data.forEach((key, value) {
        links![int.parse(key)] = List<String>.from(value);
      });
    }
    directory = map["directory"];
    if(map["finishedTasks"] != null) {
      var finishedTasks = List<String>.from(map["finishedTasks"]);
      for (var task in finishedTasks) {
        _downloading[task] = _ImageDownloadWrapper.finished();
      }
    }
  }

  /// get all image links
  ///
  /// key - episode number(starts with 1), value - image links in this episode
  ///
  /// if platform don't have episode, this only have one key: 0.
  Future<Map<int, List<String>>> getLinks();

  /// 本次要下的话数。默认等于已取到的地址条数(这些源一次性取全部地址);
  /// 懒加载的源(地址带签名有效期)覆盖成"实际要下的话数"。
  int get totalEps => links?.length ?? 1;

  /// 懒加载点: 确保第 [position] 话(从 0 开始)的图片地址已在 [links] 里,
  /// 返回它在 [links] 里的 key。
  ///
  /// 默认实现适用于"getLinks 一次就取全"的源, 不需要额外做事。
  /// 图片地址带有效期(再漫画的 images 域名)的源要覆盖它, 改成只取这一话 ——
  /// 一次性预取全书地址, 隔天继续下载时那批地址已经全部过期了。
  Future<int> ensureEpLinks(int position) async {
    return links!.keys.elementAt(position);
  }

  /// whether this platform have episode
  bool get haveEps =>
      type != DownloadType.ehentai &&
      type != DownloadType.hitomi &&
      type != DownloadType.htmanga &&
      type != DownloadType.nhentai;

  Stream<DownloadProgress> downloadImage(String link);

  ///获取封面链接
  String get cover;

  ///总共的图片数量
  int get totalPages => links?.totalLength ?? 0;

  /// 懒加载的分话下载任务用"话"来显示进度: 后面的话还没取地址, 总页数不可知,
  /// 拿页数当分母会算出超过 100% 的进度。其它任务返回 null(沿用页数口径)。
  int? get episodeDone => null;

  int? get episodeTotal => null;

  ///已下载的图片数量
  int get downloadedPages => _downloadedNum;

  ///标题
  String get title;

  @override
  bool operator ==(Object other) {
    if (other is DownloadingItem) {
      return id == other.id;
    } else {
      return false;
    }
  }

  @override
  int get hashCode => id.hashCode;

  FutureOr<DownloadedItem> toDownloadedItem();

  /// 分话下载的任务每下完一话调用一次, 用于把当前进度同步进「已下载」列表。
  /// 默认空实现: 只有支持部分下载的源(如 JS 源)才需要覆写。
  /// [ep] 是这一话在 [links] 里的 key(便于覆写方知道刚下完的是哪一话)。
  Future<void> onEpisodeDownloaded(int ep) async {}

  /// 完成下载时调用, 让 DownloadManager 收尾(移出队列、释放源槽、安排下一个)。
  /// 带上自身: 并发下载时完成的未必是队首。
  void notifyDownloadFinished() {
    DownloadManager().onTaskFinished(this);
  }

  @override
  String toString() {
    return "$id: $downloadedPages/$totalPages";
  }
}

class _ImageDownloadWrapper {
  final Stream<DownloadProgress> stream;

  final String path;

  final String fileBaseName;

  final void Function(int length)? onReceiveData;

  final void Function()? onFinished;

  Object? error;

  bool isFinished = false;

  bool _canceled = false;

  void cancel() {
    _canceled = true;
  }

  _ImageDownloadWrapper(
    this.stream,
    this.path,
    this.fileBaseName,
    this.onReceiveData,
    this.onFinished,
  ) {
    listen();
  }

  _ImageDownloadWrapper.finished():
    stream = const Stream.empty(),
    path = "",
    fileBaseName = "",
    onReceiveData = null,
    onFinished = null,
    isFinished = true;

  void listen() async {
    try {
      var last = 0;
      await for (var progress in stream) {
        if(_canceled) {
          for (var c in completers) {
            c.complete(this);
          }
          return;
        }
        onReceiveData?.call(progress.currentBytes - last);
        last = progress.currentBytes;
        if (progress.finished) {
          var data = progress.data ?? await progress.getFile().readAsBytes();
          if (data.isEmpty) {
            // 源站返回 0 字节(网络中断 / 被拦截 / 图片已失效)时不能算作成功:
            // 否则上层会记为"这一页已完成", 但文件根本没写下来,
            // 表现就是下载页显示已完成、点进去却缺页。
            // 这里按失败处理并跳出, 交给 upper 层的重试逻辑。
            error = Exception("Empty image data");
            break;
          }
          var type = detectFileType(data);
          var file = File("$path/$fileBaseName${type.ext}");
          if (!await file.exists()) {
            await file.create(recursive: true);
          }
          await file.writeAsBytes(data);
          isFinished = true;
        }
      }
    } catch (e) {
      error = e;
    }
    if (!isFinished && error == null) {
      error = Exception("Failed to download image");
    }
    onFinished?.call();
    for (var c in completers) {
      c.complete(this);
    }
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  Future<_ImageDownloadWrapper> wait() {
    if (isFinished) {
      return Future.value(this);
    }
    var completer = Completer<_ImageDownloadWrapper>();
    completers.add(completer);
    return completer.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
    DownloadManager().notifyListeners();
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
  }
}
