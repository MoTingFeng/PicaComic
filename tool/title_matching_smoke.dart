import 'package:pica_comic/tools/title_matching.dart';

void main() {
  var cases = [
    '和机器人啪啪啪能算在经验次数里吗',
    '和机器人啪啪啪能算在经验次数里吗（全彩）',
    '【汉化】和机器人啪啪啪能算在经验次数里吗[第01-09话]',
    '和机器人啪啪啪能算在经验次数里吗 第6.2~6.4话',
    'SPY×FAMILY 第3卷',
    '三顆星彩色冒險 Vol.2 （作者：カツヲ）',
    '百合の園 ～放課後～',
  ];
  for (var c in cases) {
    print('$c\n  => ${normalizeTitle(c)}  |  ${fragmentTitle(c)}');
  }
  print('作者拆分: ${splitAuthors("雨野/カツヲ、無名")}');
  print('相似度: ${titleSimilarity("和机器人啪啪啪能算在经验次数里吗", "和机器人啪啪啪能算在经验次数里吗（全彩）")}');
}
