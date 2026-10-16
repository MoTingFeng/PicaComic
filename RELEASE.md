# 发版与版本号规则

本文件是发版时的唯一依据。**每次发版都必须先看这里**。

## 版本号格式

`MAJOR.MINOR.PATCH[-mod][+build]`，例如 `4.3.0-mod`。

| 部分 | 含义 | 由谁决定 |
| --- | --- | --- |
| `MAJOR.MINOR.PATCH` | 语义化版本主体 | **发版时手改**（`pubspec.yaml`）|
| `-mod` | 标明这是修改版（非上游原版）| 固定保留 |
| `+build` | versionCode | **CI 自动覆盖**为构建序号，不用手改 |

应用内「设置 → 应用信息」里显示的版本名 = `MAJOR.MINOR.PATCH-mod`。

## 递增规则

只改 `pubspec.yaml` 里的 `version`，按改动性质选一位 +1：

| 位 | 何时 +1 | 本项目例子 |
| --- | --- | --- |
| **MAJOR** | 破坏性、不兼容的变更 | 包名变更导致无法覆盖安装、数据格式不兼容 |
| **MINOR** | 新增功能（向后兼容）| 长按直接下载、多选批量下载、下载进度面板、重试失败项 |
| **PATCH** | 修复缺陷（向后兼容）| 合并上游修复、修复崩溃、修复下载缺页 |

判断顺序：**有破坏性 → MAJOR；有新增功能 → MINOR；只有修复 → PATCH**。

## 发版流程

1. 按上表判断该 + 哪一位，改 `pubspec.yaml`：
   ```yaml
   version: 4.4.0-mod+4211
   ```
   （`+` 后的数字随意，构建时会被 CI 覆盖成构建序号）
2. 如需更新发版说明，改 `.github/release_notes.md`（构建时自动带构建号与源码 commit）
3. 提交并推送 `master`
4. GitHub Actions 自动构建 → 发布到固定 Release tag **`apk-build`**
5. 手机端**覆盖安装**即可（包名与签名固定，数据保留）

## 版本代号对照

| 版本 | 主要变化 |
| --- | --- |
| 4.2.11 | 上游 Pacalini/PicaComic 基线 |
| **4.3.0-mod** | 长按封面直接下载；多选批量下载 + 进度面板（话数/页数/逐话明细/重试失败项）；下载页长按「继续下载 / 重新下载」；合并上游一二档修复；独立包名 `com.github.mo.pica_comic` 与原版共存 |

## 相关文件

| 文件 | 作用 |
| --- | --- |
| `pubspec.yaml` | 版本名来源（发版时改这里）|
| `.github/workflows/android.yml` | 构建与发布；versionCode 用 `run_number` |
| `.github/release_notes.md` | Release 说明正文 |
| `keys/`（本地，不入库）| 签名密钥，丢失则无法再更新同一 App |
