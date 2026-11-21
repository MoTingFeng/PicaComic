/// 一个可重复开关的 sqlite 连接, 只依赖 dart + sqlite3 (不 import Flutter),
/// 这样 `dart run tool/sync_merge_smoke.dart` 能直接测它的幂等行为。
library;

import 'package:sqlite3/sqlite3.dart';

/// 带状态位的 sqlite 连接句柄。
///
/// 背景 (4.10.1 平板冷启动闪退): 同步在运行时 dispose 了 history.db /
/// local_favorite.db 的连接, 而 UI 与 ImageFavoriteManager 仍在用同一个句柄,
/// 原生层出现 double free (scudo: invalid chunk state when deallocating)。
/// 这里把连接包一层状态:
///
/// - [close] 幂等: 重复调用不会二次 dispose 同一个 Database (第二次直接返回 false);
/// - [reopen] 幂等: 已经打开时不会重复 open 出一个泄漏的连接;
/// - [close] 之后通过 [db] 取连接会抛 StateError, 不会把已释放的句柄交给
///   sqlite3 原生层。
class DatabaseHandle {
  DatabaseHandle(this.path);

  final String path;

  Database? _db;

  bool get isOpen => _db != null;

  /// 当前连接。关闭后取用会抛 [StateError] (而不是踩已释放的原生句柄)
  Database get db {
    final db = _db;
    if (db == null) {
      throw StateError('database $path is closed');
    }
    return db;
  }

  /// 打开连接; 已经打开时直接返回现有连接 (不会重复 open)
  Database open() {
    final existing = _db;
    if (existing != null) {
      return existing;
    }
    final db = sqlite3.open(path);
    _db = db;
    return db;
  }

  /// 关闭连接; 返回 true 表示这次真的 dispose 了, false 表示本来就关着。
  ///
  /// 调用方只能通过这里关连接, 不要自己拿 [db] 去 dispose。
  bool close() {
    final db = _db;
    if (db == null) {
      return false;
    }
    // 先清状态再 dispose: 即使 dispose 抛异常, 也不会留下"状态是打开、实际已关闭"
    _db = null;
    db.dispose();
    return true;
  }

  /// 重开连接; 返回 true 表示这次真的重开, false 表示本来就开着 (什么也没做)
  bool reopen() {
    if (_db != null) {
      return false;
    }
    _db = sqlite3.open(path);
    return true;
  }
}
