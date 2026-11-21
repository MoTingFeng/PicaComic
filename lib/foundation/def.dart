import 'package:flutter/material.dart';

typedef ActionFunc = void Function();

enum ComicType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htManga,
  htFavorite,
  nhentai,
  other;

  @override
  toString() => name;
}

const String webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";

//App版本(关于页/检查更新/漫画源 minAppVersion 判断都用它)
//
//由 CI 通过 --dart-define=APP_VERSION 注入 pubspec.yaml 的版本名, 发版只改一处;
//本地直接 flutter run 时用下面的默认值兜底(不参与发版, 过期也不影响 CI 产物)
const appVersion =
    String.fromEnvironment("APP_VERSION", defaultValue: "4.10.2-mod");

//定义宽屏设备的临界值
const changePoint = 600;
const changePoint2 = 1300;

List<MaterialAccentColor> get colors => [
  Colors.redAccent,
  Colors.pinkAccent,
  Colors.purpleAccent,
  Colors.indigoAccent,
  Colors.blueAccent,
  Colors.cyanAccent,
  Colors.tealAccent,
  Colors.greenAccent,
  Colors.limeAccent,
  Colors.yellowAccent,
  Colors.amberAccent,
  Colors.orangeAccent,
];

const builtInSources = [
  "picacg",
  "ehentai",
  "jm",
  "hitomi",
  "htmanga",
  "nhentai"
];