import 'dart:convert';
import 'dart:typed_data';

import 'package:pica_comic/foundation/sync/sync_protocol.dart';
import 'package:pica_comic/foundation/sync/sync_service.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// WebDAV 连接配置: `URL;用户名;密码;路径` (设置 settings[45] 的格式)
class WebdavConfig {
  final String url;

  final String user;

  final String password;

  /// 远端根路径, 以 / 结尾
  final String root;

  const WebdavConfig(this.url, this.user, this.password, this.root);

  static WebdavConfig? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final configs = raw.split(';');
    // 旧版失败后会往配置尾部追加 ";0" 来禁用同步, 长度不是 4 一律视为未配置
    if (configs.length != 4 || configs[0].isEmpty) {
      return null;
    }
    var root = configs[3];
    if (root.isEmpty) {
      root = '/';
    }
    if (!root.endsWith('/')) {
      root += '/';
    }
    return WebdavConfig(configs[0], configs[1], configs[2], root);
  }

  String remotePath(String relative) => '$root$relative';
}

/// WebDAV 传输层: 只负责读写文件, 快照内容与合并由 [SyncService] 处理。
///
/// 兼容旧调用点: [uploadData]/[downloadData]/[syncData] 语义已改成
/// 「上传自己的设备快照」/「合并同步」。
class Webdav {
  static webdav.Client _client(WebdavConfig config, {int connectTimeoutMs = 8000}) {
    final client = webdav.newClient(
      config.url,
      user: config.user,
      password: config.password,
      debug: false,
    );
    client.setConnectTimeout(connectTimeoutMs);
    return client;
  }

  /// 列出目录下的文件与子目录
  static Future<List<webdav.File>> listDir(
      WebdavConfig config, String path) async {
    return (await _client(config).readDir(path));
  }

  /// 确保 devices/ 目录存在 (已存在时服务器可能报错, 忽略)
  static Future<void> ensureDevicesDir(WebdavConfig config) async {
    try {
      await _client(config).mkdir(config.remotePath(syncDevicesDirName));
    } catch (_) {
      // 目录已存在或服务器不允许 MKCOL, 后续上传会暴露真实错误
    }
  }

  static Future<void> uploadFile(
      WebdavConfig config, String remotePath, String localPath) async {
    await _client(config).writeFromFile(localPath, remotePath);
  }

  static Future<void> downloadFile(
      WebdavConfig config, String remotePath, String localPath) async {
    await _client(config).read2File(remotePath, localPath);
  }

  static Future<void> writeText(
      WebdavConfig config, String remotePath, String text) async {
    await _client(config).write(remotePath, Uint8List.fromList(utf8.encode(text)));
  }

  static Future<String?> readText(WebdavConfig config, String remotePath) async {
    try {
      final bytes = await _client(config).read(remotePath);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 兼容旧调用点
  // -------------------------------------------------------------------------

  /// 本地有变更时调用 (history/favorites/settings 里大量调用):
  /// 不带 config = 防抖 5 秒后上传自己的快照; 带 config = 立即上传。
  static Future<bool> uploadData([String? config]) async {
    if (config != null) {
      return SyncService.instance.uploadNow(config: config);
    }
    SyncService.instance.markDirty();
    return true;
  }

  /// 兼容旧入口: 下载(现在是双向合并)
  static Future<bool> downloadData([String? config]) async {
    final result = await SyncService.instance.syncNow(config: config);
    return result.success;
  }

  /// 兼容旧入口: 弹加载框手动同步
  static void syncData() async {
    await SyncService.instance.manualSync();
  }
}
