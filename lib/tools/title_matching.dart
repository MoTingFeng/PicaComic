/// 标题归一化与相似度: 用于「在其他源搜索」构造查询串、给结果打分。
///
/// 不同源对同一部作品的写法差别很大(全彩/汉化/第N话/作者括注/装饰符号),
/// 这里把标题洗成"可以拿来比较"的形式, 同时留一个"节选"用于名称后半段不同的情况。
library;

/// 括号: 只删括号本身, 里面的文字保留(书名号之类)
const _brackets = [
  '《', '》', '〈', '〉', '「', '」', '『', '』', '【', '】',
  '(', ')', '[', ']', '（', '）', '［', '］', '〔', '〕',
];

/// 装饰符号: 直接删
const _decorations = [
  '！', '？', '!', '?', '～', '~', '·', '•', '×', '✕', '※', '…',
  '、', '，', '。', '/', '\\', '|', '｜', '+', '&', '＆',
  '★', '☆', '♥', '♡', '⭐', '✨', '_', '—', '－', '-',
];

/// 版本/状态类词: 出现在括注里就整段丢掉
final _versionWords = RegExp(
    r'(全彩|彩色|無修|无修|无修正|漢化|汉化|中文|简体|繁體|繁体|完结|連載|连载|更新至|DL版|单行本|生肉|熟肉|合订本|合集|短篇|番外|外传|前传|成年|成年向|一般向|r18|18禁|無料|试看|目录|目錄)',
    caseSensitive: false);

/// 括注里是这些开头(作者/汉化组之类)也整段丢掉
final _authorishBracket = RegExp(r'^(作者|原作|作画|畫師|画师|漢化|汉化|翻译|譯者|译者)');

/// 章节/卷尾巴(中文): 第12话 / 第6.2~6.4话 / 第3卷
final _chapterTailCn = RegExp(
    r'第\s*\d+(?:\.\d+)?(?:\s*[~～-]\s*\d+(?:\.\d+)?)?\s*(?:[话話集卷季部章]|回)\s*$');

/// 章节/卷尾巴(拉丁): Vol.2 / ch.5 / chapter 3
final _chapterTailLatin = RegExp(
    r'(?:vol\.?|volume|ch\.?|chapter)\s*\d+(?:\.\d+)?\s*$',
    caseSensitive: false);

/// 「更新至第9话」这类尾巴
final _updateTail = RegExp(r'(更新至|连载至|连载到|已更新至).*$');

/// 只保留: 数字 / 拉丁字母 / 假名 / 汉字 / 韩文; 其它一律当分隔
final _keep = RegExp(
    r'[^0-9A-Za-z\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]');

/// 全角转半角(含全角空格)
String toHalfWidth(String s) {
  var buffer = StringBuffer();
  for (var rune in s.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// 归一化标题: 去掉版本词/章节尾巴/装饰符号, 只留文字与数字
String normalizeTitle(String raw) {
  var s = toHalfWidth(raw).toLowerCase();
  // 1. 括注: 版本词或作者信息整段丢弃, 其它只删括号
  s = s.replaceAllMapped(RegExp(r'[（(\[【〔]([^）)\]】〕]*)[）)\]】〕]'), (m) {
    var inner = (m.group(1) ?? '').trim();
    if (_versionWords.hasMatch(inner)) {
      return ' ';
    }
    if (_authorishBracket.hasMatch(inner)) {
      return ' ';
    }
    if (RegExp(r'^[第\s]*\d+(?:\.\d+)?\s*[话話卷集]?$').hasMatch(inner)) {
      return ' ';
    }
    return inner;
  });
  // 2. 章节/卷/更新状态尾巴
  s = s.replaceAll(_chapterTailCn, ' ');
  s = s.replaceAll(_chapterTailLatin, ' ');
  s = s.replaceAll(_updateTail, ' ');
  // 3. 括号与装饰
  for (var c in _brackets) {
    s = s.replaceAll(c, ' ');
  }
  for (var c in _decorations) {
    s = s.replaceAll(c, ' ');
  }
  // 4. 只留文字数字, 折叠空白
  return s.replaceAll(_keep, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 节选: 名称后半段不同时用的第二查询。
///
/// 先按空格逐段累加(避免 SPY FAMILY / 百合の園 放課後 被切碎), 够长再截 14 字。
String fragmentTitle(String raw, {int minLength = 8, int maxLength = 14}) {
  var normalized = normalizeTitle(raw);
  if (normalized.isEmpty) {
    // 归一化后什么都不剩(比如标题里只有"第3话"), 退回原文
    return raw.trim();
  }
  var tokens = normalized.split(' ').where((e) => e.isNotEmpty).toList();
  var buffer = StringBuffer();
  for (var token in tokens) {
    buffer.write(token);
    if (buffer.length >= minLength) {
      break;
    }
  }
  var merged = buffer.toString();
  if (merged.length <= maxLength) {
    return merged;
  }
  return String.fromCharCodes(merged.runes.take(maxLength));
}

/// 作者串拆成多个候选: "作者A/作者B、作者C" -> [A, B, C]
List<String> splitAuthors(String? raw) {
  if (raw == null) {
    return const [];
  }
  const placeholders = {'未知', 'N/A', 'n/a', '无', 'none', 'null', 'unknown', '-', '—', '無名', '无名', '佚名'};
  return raw
      .split(RegExp(r'[/、,，&＆|｜]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && !placeholders.contains(e))
      .toList();
}

/// 两个标题的相似度 0~1
double titleSimilarity(String a, String b) {
  var x = normalizeTitle(a).replaceAll(' ', '');
  var y = normalizeTitle(b).replaceAll(' ', '');
  if (x.isEmpty || y.isEmpty) {
    return 0;
  }
  if (x == y) {
    return 1;
  }
  if (x.contains(y) || y.contains(x)) {
    var shortLen = x.length < y.length ? x.length : y.length;
    var longLen = x.length < y.length ? y.length : x.length;
    return 0.75 + 0.2 * shortLen / longLen;
  }
  Set<String> grams(String s) {
    var result = <String>{};
    var chars = s.runes.toList();
    for (var i = 0; i + 1 < chars.length; i++) {
      result.add(String.fromCharCodes([chars[i], chars[i + 1]]));
    }
    return result;
  }
  var ga = grams(x);
  var gb = grams(y);
  var inter = ga.intersection(gb).length;
  var union = ga.union(gb).length;
  return union == 0 ? 0 : inter / union;
}
