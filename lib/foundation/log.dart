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

  static void writeLog(LogLevel level, String title, String content) {
    var file = logFile;
    if (file == null) {
      return;
    }
    file.writeAsString(
      "${DateTime.now().toIso8601String()} ${level.name}\n$title: $content\n\n",
      mode: FileMode.append,
    );
    // 每写若干条查一次体积, 免得一次长下载把日志写成几个 G
    if (++_writesSinceSizeCheck >= 200) {
      _writesSinceSizeCheck = 0;
      try {
        if (file.existsSync() && file.lengthSync() > maxLogFileSize) {
          _rotateFiles(file);
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
