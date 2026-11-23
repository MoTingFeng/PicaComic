import 'dart:io';

import 'package:pica_comic/foundation/log.dart';

/// 回归测试: 并发写日志不能丢行。
///
/// 背景: 以前每条日志都是 `file.writeAsString(mode: append)` 且不 await,
/// dart:io 的 append 是「打开 -> 定位到末尾 -> 写」, 并发时两次写会定位到同一个
/// 偏移互相覆盖。真机日志里因此出现过行首被吃掉、文件末尾半条记录的情况,
/// 崩溃现场直接查不出来。现在统一走单个 IOSink, 这里守住「一条都不能丢」。
Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('pica_log_smoke');
  final file = File('${dir.path}/log.txt');
  LogManager.logFile = file;

  const count = 600;
  final payload = 'x' * 120;
  for (var i = 0; i < count; i++) {
    LogManager.addLog(LogLevel.info, 'T$i', payload);
  }
  // 等 IOSink 把缓冲写进内核(之后就是操作系统负责落盘)
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final content = file.readAsStringSync();
  final missing = <int>[];
  for (var i = 0; i < count; i++) {
    if (!content.contains('T$i: $payload')) {
      missing.add(i);
    }
  }
  final ok = missing.isEmpty;
  print('并发写入 $count 条日志, 丢失 ${missing.length} 条'
      '${missing.isEmpty ? '' : ', 头几条: ${missing.take(5).toList()}'}');
  print('文件大小 ${content.length} 字节');
  print(ok ? 'PASS 日志并发写入不丢行' : 'FAIL 日志并发写入丢行');

  LogManager.logFile = null;
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  if (!ok) {
    exitCode = 1;
  }
}
