import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/pages/downloading_page.dart';
import '../foundation/app.dart';
import '../foundation/log.dart';

class Notifications {
  FlutterLocalNotificationsPlugin? flutterLocalNotificationsPlugin;
  final progressId = 72382;

  Future<bool?> requestPermission() async {
    try {
      if (App.isAndroid) {
        return await flutterLocalNotificationsPlugin!
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()!
            .requestNotificationsPermission();
      } else if (App.isIOS) {
        return await flutterLocalNotificationsPlugin
            ?.resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            );
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> init() async {
    if (!(App.isAndroid || App.isIOS)) return;
    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@drawable/notification');
    final DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
            onDidReceiveLocalNotification: onDidReceiveLocalNotification);
    InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );
    await flutterLocalNotificationsPlugin!.initialize(initializationSettings,
        onDidReceiveNotificationResponse: onDidReceiveNotificationResponse);
  }

  void onDidReceiveNotificationResponse(
      NotificationResponse notificationResponse) async {
    if (!(App.isAndroid || App.isIOS)) return;
    final String? payload = notificationResponse.payload;
    if (payload != "item y") {
      App.globalTo(() => const DownloadingPage());
    }
  }

  void onDidReceiveLocalNotification(
      int id, String? title, String? body, String? payload) async {
    if (payload != "item y") {
      App.globalTo(() => const DownloadingPage());
    }
  }

  /// 通知插件的失败不能逃逸成未捕获异常。
  ///
  /// 平板上 flutter_local_notifications 反序列化旧的通知缓存时会抛
  /// PlatformException(error, Missing type parameter.), 调用点在下载结束
  /// 的收尾路径上 —— 下载本身已经完成, 通知失败不该再崩一次。
  /// 同一个动作在窗口期内只记一条 warning, 免得每次进度刷新都刷日志。
  void _logNotificationFailure(String action, Object e) {
    LogManager.addLogThrottled("notification_fail_$action", LogLevel.warning,
        "Notification", "$action失败(已忽略): $e",
        window: const Duration(minutes: 10));
  }

  void sendProgressNotification(
      int progress, int total, String title, String content) async {
    if (!(App.isAndroid || App.isIOS)) return;
    try {
      AndroidNotificationDetails androidNotificationDetails =
          AndroidNotificationDetails('download', '下载漫画'.tl,
              channelDescription: '显示下载进度'.tl,
              importance: Importance.low,
              priority: Priority.low,
              showProgress: true,
              maxProgress: total,
              progress: progress,
              ongoing: true,
              onlyAlertOnce: true,
              autoCancel: false);
      DarwinNotificationDetails ios = const DarwinNotificationDetails(
          presentSound: false, presentAlert: false, presentBadge: false,
          presentBanner: false);
      NotificationDetails notificationDetails =
          NotificationDetails(android: androidNotificationDetails, iOS: ios);
      await flutterLocalNotificationsPlugin?.show(
          progressId, title, content, notificationDetails,
          payload: 'item x');
    } catch (e) {
      _logNotificationFailure("更新下载进度通知", e);
    }
  }

  void endProgress() async {
    if (!(App.isAndroid || App.isIOS)) return;
    try {
      await flutterLocalNotificationsPlugin?.cancel(progressId);
    } catch (e) {
      _logNotificationFailure("结束下载进度通知", e);
    }
  }

  void cancelAll() async {
    if (!(App.isAndroid || App.isIOS)) return;
    try {
      await flutterLocalNotificationsPlugin!.cancelAll();
    } catch (e) {
      // ignore
    }
  }

  void sendNotification(String title, String content) async {
    if (!(App.isAndroid || App.isIOS)) return;
    AndroidNotificationDetails androidNotificationDetails =
        const AndroidNotificationDetails(
      'PicaComic',
      'notification',
      channelDescription: 'notification',
      importance: Importance.max,
      priority: Priority.max,
    );
    DarwinNotificationDetails ios = const DarwinNotificationDetails();
    NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails, iOS: ios);
    await flutterLocalNotificationsPlugin!
        .show(1145140, title, content, notificationDetails, payload: 'item x');
  }

  void sendUnimportantNotification(String title, String content) async {
    if (!(App.isAndroid || App.isIOS)) return;
    AndroidNotificationDetails androidNotificationDetails =
        const AndroidNotificationDetails(
      'punchIN',
      '打卡',
      channelDescription: '打卡',
      importance: Importance.low,
      priority: Priority.low,
    );

    DarwinNotificationDetails ios = const DarwinNotificationDetails(
        presentAlert: false, presentSound: false, presentBadge: false);

    NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails, iOS: ios);
    await flutterLocalNotificationsPlugin!
        .show(51515568, title, content, notificationDetails, payload: 'item y');
  }
}
