import 'dart:async';
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

/// 上次拉起邮件 App 的时间, 用于 10 秒内拦截重复点击。
///
/// 邮件 App 发完不会自动把 PicaComic 带回前台, 用户手动返回后再点一次,
/// 很容易重复发两封日志邮件。文件级静态时间戳够用, 不必引入全局状态。
DateTime? _lastMailLaunch;

const _mailLaunchCooldown = Duration(seconds: 10);

/// 拉起邮件 App 后最多等多久来识别「打不开」。
///
/// FlutterEmailSender 在 Android 上用 startActivityForResult 拉起邮件 App,
/// 只有邮件 Activity 返回结果时 Future 才完成; QQ邮箱 这类 App 发送完不回传结果,
/// 所以这个 Future 可能永远不完成, 更不能拿它等「发送成功」。
/// 手机上没有任何邮件 App 时插件会在同一次方法调用里立刻回 not_available 错误,
/// 熬过这段宽限期还没报错就当作已经调起。
/// 宽限期必须很短: 邮件 App 一起来就会盖住本页面, App 进入 paused 后不再出帧,
/// 提示再晚就等于没提示了。
const _mailLaunchGrace = Duration(milliseconds: 400);

/// 「等回到前台」监听的最长存活时间, 到点强制释放, 避免监听泄漏。
const _mailReturnWindow = Duration(seconds: 30);

/// 当前正在等「回到前台」的那一个监听; 同一时刻只需要一个。
_MailReturnWatcher? _mailReturnWatcher;

/// 把本次运行的日志当附件, 交给手机上的邮件 App 发送。
///
/// 收件地址取自 settings[91], 只存在用户本机, App 内不写死任何邮箱:
/// 留空就不让发, 别人拿到安装包也没法把日志发到别处。
///
/// 第三方邮件 App 发送完通常停在它自己的界面(真机 logcat 已确认 QQ邮箱 发送后
/// PicaComic 没有 on_resume), 所以这里只补提示与返回确认, 不改变发送方式。
Future<void> sendLogByEmail() async {
  var last = _lastMailLaunch;
  if (last != null && DateTime.now().difference(last) < _mailLaunchCooldown) {
    showToast(message: "已在上一次发送流程中".tl);
    return;
  }
  var to = appdata.settings[91].trim();
  if (to.isEmpty) {
    showToast(message: "先到「设置 → APP → 日志上报邮箱」填写收件地址".tl);
    return;
  }
  var subject = "[PicaComic] $appVersion ${_logTimestamp()}";
  var body = _logMailBody();
  List<String> attachments;
  try {
    attachments = await _prepareLogAttachments();
  } catch (e) {
    showToast(message: "${"准备日志文件失败".tl}: $e");
    return;
  }
  // 先登记「回到前台」监听, 再拉起邮件 App: 反过来(等 send 回来再登记)
  // 会错过第一次 resume, 返回提示就永远不出现。
  _mailReturnWatcher?.cancel();
  var watcher =
      _MailReturnWatcher(() => showToast(message: "已返回 PicaComic".tl));
  _mailReturnWatcher = watcher;
  watcher.start();
  _lastMailLaunch = DateTime.now();
  // 这句必须在拉起邮件 App 之前显示: 邮件 App 一起来就会盖住本页, App 进入 paused 后
  // 不再出帧, 之后插入的 toast 到 2 秒被回收时一次都没画过, 等于没提示。
  showToast(message: "已打开邮件 App, 发送完成请手动返回 PicaComic".tl);
  try {
    // 带附件时只会列出邮件类 App(QQ邮箱/Outlook/Gmail 等), 收件人与附件都已填好,
    // 用户确认发送即可。这个 Future 要到邮件 App 返回才完成, 因此只等一个很短的
    // 宽限期: 没有邮件 App 时会立刻抛错并走下面的系统分享兜底, 超时说明 App 已被拉起。
    await FlutterEmailSender.send(Email(
      recipients: [to],
      subject: subject,
      body: body,
      attachmentPaths: attachments,
    )).timeout(_mailLaunchGrace, onTimeout: () {});
  } catch (e) {
    watcher.cancel();
    _mailReturnWatcher = null;
    LogManager.addLog(LogLevel.error, "Email", "邮件 App 打不开, 改用系统分享: $e");
    // 手机上没有任何注册了 mailto 的邮件 App(或系统不支持该 intent)时退一步:
    // 走系统分享面板, 由用户挑任意 App 发送, 收件人写在正文里, 需要自己填
    try {
      await Share.shareXFiles(
        attachments.map((path) => XFile(path)).toList(),
        subject: subject,
        text: "${"收件人".tl}: $to\n\n$body",
      );
    } catch (e) {
      showToast(message: "${"发送失败".tl}: $e");
    }
    return;
  }
}

/// 等一次「App 回到前台」: 用户从邮件 App 手动返回时给一句确认, 随后立刻释放监听。
///
/// 日志页可能已不在栈顶(甚至 App 还在后台), 不能依赖 widget 的 State,
/// 所以直接用 AppLifecycleListener 挂到 WidgetsBinding 上:
/// 构造时 addObserver, 释放时 dispose() 内部 removeObserver。
class _MailReturnWatcher {
  _MailReturnWatcher(this.onReturn);

  final VoidCallback onReturn;

  AppLifecycleListener? _listener;
  Timer? _guard;

  void start() {
    if (_listener != null) {
      return;
    }
    _listener = AppLifecycleListener(onResume: _handleResume);
    // 兜底: 用户可能一直停在邮件 App 里不回来, 不能让监听永久挂着。
    _guard = Timer(_mailReturnWindow, _release);
  }

  void _handleResume() {
    _release();
    if (_mailReturnWatcher == this) {
      _mailReturnWatcher = null;
    }
    onReturn();
  }

  void cancel() => _release();

  void _release() {
    _guard?.cancel();
    _guard = null;
    _listener?.dispose();
    _listener = null;
  }
}

/// 准备要发出去的日志文件, 返回它们的路径。
///
/// 一次带三份: 当前这一轮 + 轮转保留的前两轮。
/// 崩溃后重开 App, 崩溃那一轮的日志已经变成 log.txt.1,
/// 只发 log.txt 会丢掉崩溃现场。
Future<List<String>> _prepareLogAttachments() async {
  var dir = await getTemporaryDirectory();
  var result = <String>[];
  var main = LogManager.logFile;
  if (main != null && main.existsSync()) {
    var sources = <(String, File)>[
      ("current", main),
      ("prev1", File("${main.path}.1")),
      ("prev2", File("${main.path}.2")),
    ];
    for (var entry in sources) {
      if (!entry.$2.existsSync()) {
        continue;
      }
      var copy = File("${dir.path}$pathSep${_logFileName(entry.$1)}");
      await entry.$2.copy(copy.path);
      result.add(copy.path);
    }
  }
  if (result.isEmpty) {
    // iOS 等没有落盘日志的平台: 退回内存里的日志
    var path = "${dir.path}$pathSep${_logFileName("memory")}";
    await File(path).writeAsString(LogManager().toString());
    result.add(path);
  }
  return result;
}

String _logFileName([String label = "current"]) =>
    "pica-log-$label-${_logTimestamp()}.txt";

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
  lines.add("附件: 当前日志 + 上次启动的日志(如有, 用于定位崩溃)。");
  return lines.join("\n");
}
