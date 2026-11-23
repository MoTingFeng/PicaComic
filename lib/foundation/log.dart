import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pica_comic/tools/extensions.dart';

void log(String content,
    [String title = "debug", LogLevel level = LogLevel.info]) {
  LogManager.addLog(level, title, content);
}

class LogManager {
  static final List<Log> _logs = <Log>[];

  static List<Log> get logs => _logs;

  static const maxLogLength = 3000;

  static const maxLogNumber = 500;

  static bool ignoreLimitation = false;

  static void printWarning(String text) {
    print('\x1B[33m$text\x1B[0m');
  }

  static void printError(String text) {
    print('\x1B[31m$text\x1B[0m');
  }

  static void addLog(LogLevel level, String title, String content) {
    // 统一在这里脱敏: 所有写入日志的调用点(尤其是网络层打印的请求头与请求体)
    // 都不会把密码/token/cookie 明文落盘
    content = maskSecrets(content);
    if (!ignoreLimitation && content.length > maxLogLength) {
      content = "${content.substring(0, maxLogLength)}...";
    }

    if (kDebugMode) {
      switch (level) {
        case LogLevel.error:
          printError("$title: $content");
        case LogLevel.warning:
          printWarning("$title: $content");
        case LogLevel.info:
          print("$title: $content");
      }
    }

    var newLog = Log(level, title, content);

    if (newLog == _logs.lastOrNull) {
      return;
    }

    _logs.add(newLog);
    writeLog(level, title, content);
    if (_logs.length > maxLogNumber) {
      var res = _logs.remove(
          _logs.firstWhereOrNull((element) => element.level == LogLevel.info));
      if (!res) {
        _logs.removeAt(0);
      }
    }
  }

  static void clear() => _logs.clear();

  @override
  String toString() {
    var res = "Logs\n\n";
    for (var log in _logs) {
      res += log.toString();
    }
    return res;
  }

  static File? logFile;

  /// 单份日志上限: 长时间下载会往日志里写大量网络往返, 超过就轮转
  static const maxLogFileSize = 4 * 1024 * 1024;

  /// 保留几份历史日志: 崩溃后重开 App 还能看到崩溃那一轮的记录
  static const maxLogHistory = 2;

  /// 启动时调用: 把上一轮的日志轮转保留, 不再直接删掉
  static void rotateOnStart() {
    var file = logFile;
    if (file == null || !file.existsSync()) {
      return;
    }
    // 启动时正常还没有写入器; 万一有, 先关掉, 否则改名之后旧 fd 会继续写进 .1
    final sink = _sink;
    _sink = null;
    sink?.close();
    _rotateFiles(file);
  }

  static void _rotateFiles(File file) {
    try {
      var oldest = File("${file.path}.$maxLogHistory");
      if (oldest.existsSync()) {
        oldest.deleteSync();
      }
      for (var i = maxLogHistory - 1; i >= 1; i--) {
        var src = File("${file.path}.$i");
        if (src.existsSync()) {
          src.renameSync("${file.path}.${i + 1}");
        }
      }
      file.renameSync("${file.path}.1");
    } catch (e) {
      print("Failed to rotate log file: $e");
    }
  }

  static int _writesSinceSizeCheck = 0;

  /// 日志写入器: 整个进程只用一个 append 模式的 IOSink。
  ///
  /// 不能每条都 `file.writeAsString(mode: append)`: dart:io 的 append 是
  /// 「打开 -> 定位到文件末尾 -> 写」, 并发调用时两次写会定位到同一个偏移而互相覆盖。
  /// 网络/同步密集时日志会被吃掉大半(本机压测: 800 条一次性并发只活下来 2 条,
  /// 并发度 4 时丢 600 条), 崩溃现场全靠日志, 丢行等于丢证据。
  /// 换成单个 IOSink 做同样的压测是 0 丢失。
  static IOSink? _sink;

  /// 正在轮转文件: 期间的日志先攒着, 轮转完成后按顺序补写到新文件
  static bool _rotating = false;

  static final List<String> _duringRotation = <String>[];

  static void _write(String text) {
    if (_rotating) {
      _duringRotation.add(text);
      return;
    }
    try {
      // 注意: 不能在中途调 sink.flush() —— 这个 IOSink 上 flush 与后续 write
      // 并发时会让后面的写直接抛 "StreamSink is bound to a stream", 压测里表现为
      // flush 之后的几百条全部丢失。写入器本身是持续往内核写的, 进程被杀不会丢
      // 已写出的数据, 所以不需要手动 flush。
      (_sink ??= logFile!.openWrite(mode: FileMode.append)).write(text);
    } catch (e) {
      print("Failed to write log: $e");
    }
  }

  /// 先关写入器再改名, 否则 rename 之后旧 fd 会继续把日志写进 .1
  static Future<void> _rotateAsync(File file) async {
    if (_rotating) {
      return;
    }
    _rotating = true;
    try {
      final sink = _sink;
      _sink = null;
      if (sink != null) {
        await sink.flush();
        await sink.close();
      }
      _rotateFiles(file);
    } catch (e) {
      print("Failed to rotate log file: $e");
    } finally {
      _rotating = false;
      final pending = List<String>.from(_duringRotation);
      _duringRotation.clear();
      for (final text in pending) {
        _write(text);
      }
    }
  }

  static void writeLog(LogLevel level, String title, String content) {
    if (logFile == null) {
      return;
    }
    _write("${DateTime.now().toIso8601String()} ${level.name}\n$title: $content\n\n");
    // 每写若干条查一次体积, 免得一次长下载把日志写成几个 G
    if (++_writesSinceSizeCheck >= 200) {
      _writesSinceSizeCheck = 0;
      final file = logFile!;
      try {
        if (file.existsSync() && file.lengthSync() > maxLogFileSize) {
          unawaited(_rotateAsync(file));
        }
      } catch (e) {
        print("Failed to check log size: $e");
      }
    }
  }

  /// 日志里不能出现密码/token/cookie 明文: 日志会被导出、也会被发到邮箱
  static final _secretPattern = RegExp(
      "(password|passwd|pwd|tokenparam|token|authorization|signature|api-key|set-cookie|cookie|access_token|refresh_token|secret)\\s*[:=]\\s*([^,;&}\\n\\r\"]+)",
      caseSensitive: false);

  static String maskSecrets(String text) {
    return text.replaceAllMapped(_secretPattern, (m) => "${m.group(1)}: ***");
  }

  /// 同一条日志在窗口期内只记一次(握手失败/重试这类一次网络故障会刷上千条)
  static final _throttle = <String, DateTime>{};

  static void addLogThrottled(String key, LogLevel level, String title,
      String content, {Duration window = const Duration(seconds: 30)}) {
    var now = DateTime.now();
    var last = _throttle[key];
    if (last != null && now.difference(last) < window) {
      return;
    }
    _throttle[key] = now;
    if (_throttle.length > 100) {
      _throttle.remove(_throttle.keys.first);
    }
    addLog(level, title, content);
  }

  static String? _lastUnhandled;

  static DateTime? _lastUnhandledAt;

  /// 未捕获异常落盘: 同一个异常 30 秒内只记一次,
  /// 否则一次代理/TLS 故障就能把日志刷满几百条栈
  static void logUnhandled(Object error, StackTrace? stack) {
    var text = error.toString();
    var now = DateTime.now();
    if (text == _lastUnhandled &&
        _lastUnhandledAt != null &&
        now.difference(_lastUnhandledAt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastUnhandled = text;
    _lastUnhandledAt = now;
    addLog(LogLevel.error, "Unhandled Exception", "$text\n$stack");
  }
}

class Log {
  final LogLevel level;
  final String title;
  final String content;
  final DateTime time = DateTime.now();

  @override
  toString() => "${level.name} $title $time \n$content\n\n";

  Log(this.level, this.title, this.content);

  static void info(String title, String message) {
    LogManager.addLog(LogLevel.info, title, message);
  }

  static void warning(String title, String message) {
    LogManager.addLog(LogLevel.warning, title, message);
  }

  static void error(String title, String message) {
    LogManager.addLog(LogLevel.error, title, message);
  }

  @override
  bool operator ==(Object other) {
    if (other is! Log)  return false;
    return other.level == level && other.title == title && other.content == content;
  }

  @override
  int get hashCode => level.hashCode ^ title.hashCode ^ content.hashCode;
}

enum LogLevel { error, warning, info }
