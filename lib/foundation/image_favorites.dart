part of "history.dart";

// 直接用history.db了, 没必要再加一个favorites.db

class ImageFavorite{
  /// unique id for the comic
  final String id;

  final String imagePath;

  final String title;

  final int ep;

  final int page;

  final Map<String, dynamic> otherInfo;

  const ImageFavorite(this.id, this.imagePath, this.title, this.ep, this.page, this.otherInfo);
}

class ImageFavoriteManager{
  static Database get _db => HistoryManager()._db;

  /// 检查表image_favorites是否存在, 不存在则创建。
  ///
  /// updatedAt 供 WebDAV 同步判断谁更新; image_tombstone 记删除墓碑, 让删除跨设备生效。
  static void init(){
    _db.execute("CREATE TABLE IF NOT EXISTS image_favorites ("
        "id TEXT,"
        "title TEXT NOT NULL,"
        "cover TEXT NOT NULL,"
        "ep INTEGER NOT NULL,"
        "page INTEGER NOT NULL,"
        "other TEXT NOT NULL,"
        "updatedAt INTEGER,"
        "PRIMARY KEY (id, ep, page)"
        ");");
    var columns = _db.select('PRAGMA table_info(image_favorites);');
    if (columns.every((row) => row["name"] != "updatedAt")) {
      _db.execute("alter table image_favorites add column updatedAt INTEGER;");
    }
    _db.execute("CREATE TABLE IF NOT EXISTS image_tombstone ("
        "id TEXT,"
        "ep INTEGER,"
        "page INTEGER,"
        "deleted_at INTEGER,"
        "PRIMARY KEY (id, ep, page)"
        ");");
    var before = DateTime.now().millisecondsSinceEpoch -
        const Duration(days: 90).inMilliseconds;
    _db.execute("delete from image_tombstone where deleted_at < ?;", [before]);
  }

  static void add(ImageFavorite favorite){
    _db.execute("""
      insert into image_favorites(id, title, cover, ep, page, other, updatedAt)
      values(?, ?, ?, ?, ?, ?, ?);
    """, [favorite.id, favorite.title, favorite.imagePath, favorite.ep, favorite.page, jsonEncode(favorite.otherInfo),
      DateTime.now().millisecondsSinceEpoch]);
    _db.execute("""
      delete from image_tombstone
      where id = ? and ep = ? and page = ?;
    """, [favorite.id, favorite.ep, favorite.page]);
    Webdav.uploadData();
    Future.microtask(() => StateController.findOrNull(tag: "me_page")?.update());
  }

  static List<ImageFavorite> getAll(){
    var res = _db.select("select * from image_favorites;");
    return res.map((e) =>
        ImageFavorite(e["id"], e["cover"], e["title"], e["ep"], e["page"], jsonDecode(e["other"]))).toList();
  }

  static void delete(ImageFavorite favorite){
    _db.execute("""
      delete from image_favorites
      where id = ? and ep = ? and page = ?;
    """, [favorite.id, favorite.ep, favorite.page]);
    _db.execute("""
      insert or replace into image_tombstone(id, ep, page, deleted_at)
      values(?, ?, ?, ?);
    """, [favorite.id, favorite.ep, favorite.page,
      DateTime.now().millisecondsSinceEpoch]);
    Webdav.uploadData();
  }

  static bool exist(String id, int ep, int page) {
    var res = _db.select("""
      select * from image_favorites
      where id = ? and ep = ? and page = ?;
    """, [id, ep, page]);
    return res.isEmpty ? false : true;
  }

  static int get length {
    var res = _db.select("select count(*) from image_favorites;");
    return res.first.values.first! as int;
  }
}