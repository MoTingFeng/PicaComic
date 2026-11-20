import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pica_comic/components/components.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Logs"),
        actions: [
          IconButton(onPressed: ()=>setState(() {
            final RelativeRect position = RelativeRect.fromLTRB(
              MediaQuery.of(context).size.width,
              MediaQuery.of(context).padding.top + kToolbarHeight,
              0.0,
              0.0,
            );
            showMenu(context: context, position: position, items: [
              PopupMenuItem(
                child: Text("清空".tl),
                onTap: () => setState(()=>LogManager.clear()),
              ),
              PopupMenuItem(
                child: Text("禁用长度限制".tl),
                onTap: (){
                  LogManager.ignoreLimitation = true;
                  showToast(message: "仅在本次运行时有效".tl);
                },
              ),
              PopupMenuItem(
                child: Text("导出".tl),
                onTap: () => saveLog(LogManager().toString()),
              ),
              PopupMenuItem(
                child: Text("发送到邮箱".tl),
                onTap: () => sendLogByEmail(),
              ),
            ]);
          }), icon: const Icon(Icons.more_horiz))
        ],
      ),
      body: ListView.builder(
        reverse: true,
        controller: ScrollController(),
        itemCount: LogManager.logs.length,
        itemBuilder: (context, index){
          index =  LogManager.logs.length - index - 1;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.all(Radius.circular(16)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(LogManager.logs[index].title),
                        ),
                      ),
                      const SizedBox(width: 3,),
                      Container(
                        decoration: BoxDecoration(
                          color: [
                            Theme.of(context).colorScheme.error,
                            Theme.of(context).colorScheme.errorContainer,
                            Theme.of(context).colorScheme.primaryContainer
                          ][LogManager.logs[index].level.index],
                          borderRadius: const BorderRadius.all(Radius.circular(16)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(
                            LogManager.logs[index].level.name,
                            style: TextStyle(color: LogManager.logs[index].level.index==0?Colors.white:Colors.black),),
                        ),
                      ),
                    ],
                  ),
                  Text(LogManager.logs[index].content),
                  Text(LogManager.logs[index].time.toString().replaceAll(RegExp(r"\.\w+"), "")),
                  TextButton(onPressed: (){
                    Clipboard.setData(ClipboardData(text: LogManager.logs[index].content));
                  }, child: Text("复制".tl)),
                  const Divider(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 把本次运行的日志当附件, 交给手机上的邮件 App 发送。
///
/// 收件地址取自 settings[91], 只存在用户本机, App 内不写死任何邮箱:
/// 留空就不让发, 别人拿到安装包也没法把日志发到别处。
Future<void> sendLogByEmail() async {
  var to = appdata.settings[91].trim();
  if (to.isEmpty) {
    showToast(message: "先到「设置 → APP → 日志上报邮箱」填写收件地址".tl);
    return;
  }
  var subject = "[PicaComic] $appVersion ${_logTimestamp()}";
  var body = _logMailBody();
  String attachment;
  try {
    attachment = await _prepareLogAttachment();
  } catch (e) {
    showToast(message: "${"准备日志文件失败".tl}: $e");
    return;
  }
  try {
    // 带附件时只会列出邮件类 App(QQ邮箱/Outlook/Gmail 等), 收件人与附件都已填好,
    // 用户确认发送即可
    await FlutterEmailSender.send(Email(
      recipients: [to],
      subject: subject,
      body: body,
      attachmentPaths: [attachment],
    ));
    return;
  } catch (e) {
    LogManager.addLog(LogLevel.error, "Email", "邮件 App 打不开, 改用系统分享: $e");
  }
  // 手机上没有任何注册了 mailto 的邮件 App(或系统不支持该 intent)时退一步:
  // 走系统分享面板, 由用户挑任意 App 发送, 收件人写在正文里, 需要自己填
  try {
    await Share.shareXFiles(
      [XFile(attachment)],
      subject: subject,
      text: "${"收件人".tl}: $to\n\n$body",
    );
  } catch (e) {
    showToast(message: "${"发送失败".tl}: $e");
  }
}

/// 准备要发出去的日志文件, 返回它的路径。
///
/// 优先用启动时落盘的 log.txt(本次运行的完整日志, 不受内存 500 条上限影响);
/// 没有落盘日志的平台(iOS)退回内存里的日志。
Future<String> _prepareLogAttachment() async {
  var dir = await getTemporaryDirectory();
  var path = "${dir.path}$pathSep${_logFileName()}";
  var src = LogManager.logFile;
  if (src != null && src.existsSync()) {
    await src.copy(path);
  } else {
    await File(path).writeAsString(LogManager().toString());
  }
  return path;
}

String _logFileName() => "pica-log-${_logTimestamp()}.txt";

String _logTimestamp([DateTime? time]) {
  var t = time ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, "0");
  return "${t.year}${two(t.month)}${two(t.day)}-"
      "${two(t.hour)}${two(t.minute)}${two(t.second)}";
}

/// 邮件正文: 版本/系统/时间/下载队列现状, 邮件里就能看出运行环境, 不必再回头问
String _logMailBody() {
  var t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, "0");
  var lines = <String>[
    "版本: $appVersion",
    "系统: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}",
    "时间: ${t.year}-${two(t.month)}-${two(t.day)} "
        "${two(t.hour)}:${two(t.minute)}:${two(t.second)}",
  ];
  try {
    var manager = DownloadManager();
    var tasks = manager.downloading;
    lines.add("下载队列: ${tasks.length} 本${manager.isDownloading ? "(进行中)" : "(未在下载)"}");
    var shown = 0;
    for (var task in tasks) {
      if (shown >= 20) break;
      lines.add("  - ${task.id}: ${task.downloadedPages}/${task.totalPages}");
      shown++;
    }
    if (tasks.length > shown) {
      lines.add("  ... 另有 ${tasks.length - shown} 本");
    }
  } catch (e) {
    lines.add("下载队列: 读取失败 $e");
  }
  lines.add("");
  lines.add("完整日志见附件。");
  return lines.join("\n");
}
