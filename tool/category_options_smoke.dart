import 'dart:convert';
import 'dart:io';

import 'package:pica_comic/foundation/category_options.dart';

/// 分类页选择存储的冒烟测试: 纯 dart:io, 直接用临时目录跑, 不碰用户数据
///
/// 运行: dart run tool/category_options_smoke.dart

int _passed = 0;

int _failed = 0;

void check(String name, bool ok, [Object? detail]) {
  if (ok) {
    _passed++;
    print("  PASS  $name");
  } else {
    _failed++;
    print("  FAIL  $name${detail == null ? "" : " -> $detail"}");
  }
}

void main() {
  var dir = Directory.systemTemp.createTempSync("category_options_smoke");
  print("临时目录: ${dir.path}");
  try {
    _saveAndReadBack(dir);
    _restartReadsDisk(dir);
    _debounceBeforeWrite(dir);
    _resolveFallback();
    _resolveWithoutSaved();
    _corruptedFile(dir);
    _defensiveCopy(dir);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响结论
    }
  }
  print("\n通过 $_passed 项, 失败 $_failed 项");
  if (_failed > 0) exitCode = 1;
}

const _key = "picacg|學生|a";

CategoryOptions _sample() => CategoryOptions(
      options: const ["ld"],
      // 现实里 groups 的 key 是分组标题(题材/读者群), 不是稳定 id
      groups: const {"题材": "4", "读者群": null},
    );

void _saveAndReadBack(Directory dir) {
  print("\n[保存 -> 同实例读回]");
  var store = CategoryOptionsStore(dir.path);
  check("没有记录时读回是 null", store[_key] == null);
  store.save(_key, _sample());
  var got = store[_key];
  check("同实例能读回", got != null);
  check("排序值正确", got?.options.single == "ld");
  check("分组值正确", got?.groups["题材"] == "4");
  check("分组 null 值保留",
      got != null && got.groups.containsKey("读者群") && got.groups["读者群"] == null);
  store.flush();
  check("flush 后文件存在", store.file.existsSync());
  var json = jsonDecode(store.file.readAsStringSync());
  check("文件是 json 且包含该 key", json is Map && json.containsKey(_key), json);
}

void _restartReadsDisk(Directory dir) {
  print("\n[重启: 新实例从磁盘读回]");
  var fresh = CategoryOptionsStore(dir.path);
  var got = fresh[_key];
  check("新实例读到记录", got != null);
  check("新实例排序值正确", got?.options.single == "ld");
  check("新实例分组值正确", got?.groups["题材"] == "4");
  check("新实例分组 null 值保留",
      got != null && got.groups.containsKey("读者群") && got.groups["读者群"] == null);
}

void _debounceBeforeWrite(Directory dir) {
  print("\n[写入防抖]");
  var debounceDir = Directory("${dir.path}/debounce")..createSync(recursive: true);
  var store = CategoryOptionsStore(debounceDir.path);
  store.save(_key, _sample());
  check("防抖期内还没落盘", !store.file.existsSync());
  store.flush();
  check("flush 立即落盘", store.file.existsSync());
}

void _resolveFallback() {
  print("\n[恢复到当前选项: 有效值恢复, 失效值回退默认]");
  var resolved = resolveCategoryOptions(
    saved: CategoryOptions(
      options: const ["ld"],
      groups: const {"题材": "4", "读者群": null},
    ),
    availableOptions: const [
      ["dd", "da", "ld", "vd"],
    ],
    defaultOptions: const ["dd"],
    availableGroups: const {
      "题材": ["0", "4", "999"],
      "读者群": ["3262"],
    },
    defaultGroups: const {"题材": "0", "读者群": "3262"},
  );
  check("有效排序被恢复", resolved.options.single == "ld");
  check("有效分组被恢复", resolved.groups["题材"] == "4");
  check("分组 null 值被恢复",
      resolved.groups.containsKey("读者群") && resolved.groups["读者群"] == null);

  var invalid = resolveCategoryOptions(
    saved: CategoryOptions(
      options: const ["removed", "extra"],
      groups: const {"题材": "gone", "不存在组": "1"},
    ),
    availableOptions: const [
      ["dd", "da"],
    ],
    defaultOptions: const ["dd"],
    availableGroups: const {
      "题材": ["0", "4"],
    },
    defaultGroups: const {"题材": "0"},
  );
  check("失效排序回退默认", invalid.options.single == "dd");
  check("失效分组回退默认", invalid.groups["题材"] == "0");
  check("页面上没有的分组被丢弃", !invalid.groups.containsKey("不存在组"));
}

void _resolveWithoutSaved() {
  print("\n[没有记录时全用默认]");
  var resolved = resolveCategoryOptions(
    saved: null,
    availableOptions: const [
      ["dd", "da"],
    ],
    defaultOptions: const ["dd"],
    availableGroups: const {
      "题材": ["0", "4"],
    },
    defaultGroups: const {"题材": "0"},
  );
  check("排序用默认", resolved.options.single == "dd");
  check("分组用默认", resolved.groups["题材"] == "0");
}

void _corruptedFile(Directory dir) {
  print("\n[存储损坏时不影响使用]");
  var corruptDir = Directory("${dir.path}/corrupt")..createSync(recursive: true);
  File("${corruptDir.path}/category_options.json")
      .writeAsStringSync("{ not json");
  var store = CategoryOptionsStore(corruptDir.path);
  check("损坏文件读回 null", store[_key] == null);
  store.save(_key, _sample());
  store.flush();
  var fresh = CategoryOptionsStore(corruptDir.path);
  check("损坏后能重新写入并读回", fresh[_key]?.options.single == "ld");
}

void _defensiveCopy(Directory dir) {
  print("\n[保存时做拷贝, 之后改原列表不影响记录]");
  var copyDir = Directory("${dir.path}/copy")..createSync(recursive: true);
  var store = CategoryOptionsStore(copyDir.path);
  var options = ["ld"];
  var groups = <String, String?>{"题材": "4"};
  store.save(_key, CategoryOptions(options: options, groups: groups));
  options[0] = "dd";
  groups["题材"] = "0";
  var got = store[_key];
  check("排序快照未变", got?.options.single == "ld");
  check("分组快照未变", got?.groups["题材"] == "4");
}
