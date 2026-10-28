<div align="center">

<img src="docs/assets/readme/hero.svg" alt="Capture — 原生 Mac 截图、截图美化与本地录屏工具" width="100%">

# 截得顺手，分享得漂亮。

原生 macOS 截图与录屏工具，让框选、修饰和分享连成一个顺畅的动作。

**简体中文** · [English](README.en.md)

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-24233f?style=flat-square)](docs/distribution.md)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-7763c6?style=flat-square)](https://github.com/why-evolving/capture/releases/tag/v0.6.2)
[![Public Preview](https://img.shields.io/badge/Preview-v0.6.2-458caa?style=flat-square)](https://github.com/why-evolving/capture/releases/tag/v0.6.2)
[![AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-69978b?style=flat-square)](LICENSE)

**[↓ 下载 Mac 版](https://github.com/why-evolving/capture/releases/download/v0.6.2/Capture-0.6.2-mac-arm64.zip)** · [全部版本](https://github.com/why-evolving/capture/releases) · [快速上手](#快速上手) · [开发文档](docs/README.md)

</div>

<br>

<img src="docs/assets/readme/editor.png" alt="Capture 实际编辑器：左侧工具栏、中央截图预览，右侧选择背景与预设" width="100%">

<p align="center"><sub>真实应用界面 · 示例内容由应用生成 · 当前界面以中文为主</sub></p>

## 从截图到分享，少走几步

| 随手一截 | 稍加修饰 | 录下过程 |
| --- | --- | --- |
| 快捷键呼出，画面先定格；框选后直接复制，也能移动、缩放再确认。 | 换背景、调留白，加上圆角、阴影与窗口边框。喜欢的搭配存成默认预设。 | 独立快捷键直接框选，松手倒计时；电脑声音和麦克风分别控制。 |

### 截图，保留当下的样子

- **冻结画面**：开始选取时保留画面，方便截住悬浮菜单和临时状态。
- **快截或细调**：区域、窗口、全屏；可切换直接完成与框选调整，框内拖动、边角缩放、回车确认。
- **截完就能粘贴**：自动复制，缩略图提供编辑、保存、置顶等入口。
- **长内容也能整理**：提供滚动截图与拼图工具。

### 美化，让每一张都有自己的风格

- 渐变、极光、纯色、透明及图片背景，搭配留白、圆角与阴影。
- 浅色或深色 Mac 窗口装饰；从截图提取配色，或自行调整颜色。
- 多个命名预设，支持预览、搜索、导入和导出；可指定一个默认预设并开启自动应用。
- 选区旁也能改样式；关闭自动美化，就回到普通截图。
- 复制与导出使用同一成品渲染链；预览缩放不决定输出清晰度，100% 保持源像素。

<details>
<summary><strong>查看预设管理界面</strong></summary>
<br>
<img src="docs/assets/readme/presets.png" alt="预设管理：命名样式列表、实时示例预览、截图默认标记与自动应用开关" width="100%">
</details>

### 标注、提取、继续编辑

箭头、文字、手绘与遮挡，裁剪与撤销重做；OCR 提取文字，置顶图片方便对照。可以保存可编辑的 `.capture` 项目，也可以按需开启本地历史。

> 遮挡不会从可编辑项目中删除原图。对外分享请复制或导出处理后的图片，避免发送含原图的项目文件。

### 录屏，快一点，也能调细一点

<table>
<tr>
<td width="54%" valign="top">

**快速录制**<br>
按独立快捷键，直接框选；松手后按记住的配置倒计时录制。

**需要精确范围时**<br>
切到「框选调整」，移动选框、拖动八个手柄改变大小，回车开始。倒计时也能取消或返回调整。

**声音与画质分开掌控**<br>
区域、窗口或全屏；电脑声音与麦克风独立开关、调整音量。可选择麦克风设备、画质上限、帧率、鼠标指针和倒计时。

**录完再决定怎么分享**<br>
支持暂停、继续、停止，MP4 预览、另存与恢复。录屏保留实时画面，不套用静态截图的美化预设。

</td>
<td width="46%" align="center">
<img src="docs/assets/readme/recording.png" alt="录屏设置实际界面：快速或调整选区、录制范围、电脑声音、麦克风、画质、帧率与倒计时" width="100%">
</td>
</tr>
</table>

## 快速上手

1. **[下载 v0.6.2 预览版](https://github.com/why-evolving/capture/releases/tag/v0.6.2)**，解压 ZIP，将 `Capture.app` 拖进「应用程序」。无需安装 Xcode。
2. 打开 Capture，从菜单栏使用；按欢迎页指引授予屏幕录制权限。只有需要录制麦克风时才授权麦克风，系统要求时退出重开。
3. 按截图快捷键框选，粘贴即可；想修饰时打开截后缩略图。

| 操作 | 默认快捷键 |
| --- | --- |
| 区域截图 | <kbd>⇧ Shift</kbd> + <kbd>⌘ Command</kbd> + <kbd>2</kbd> |
| 呼出录屏 / 录制时停止 | <kbd>⇧ Shift</kbd> + <kbd>⌘ Command</kbd> + <kbd>7</kbd> |
| 确认已调整的选区 | <kbd>Return</kbd> |
| 取消选区 | <kbd>Esc</kbd> |

两组全局快捷键都可在设置中单独修改。更喜欢固定样式？打开预设，选中喜欢的一项，设为默认，再开启「截图时自动套用默认预设」。

> [!IMPORTANT]
> 当前为 **Apple 芯片 Mac 的预览版**，声明最低 macOS 14；旧系统和全部硬件组合尚未完成全面验收。**未经过 Apple Developer ID 签名或公证**。若可信下载被拦截，先尝试打开，再到「系统设置 → 隐私与安全性」选择「仍要打开」。参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 与[安装指南](docs/distribution.md)。

<details>
<summary>校验下载文件</summary>

从同一版本页面下载 ZIP 和 `.zip.sha256`，在二者所在目录运行：

```sh
shasum -a 256 -c Capture-0.6.2-mac-arm64.zip.sha256
```

看到 `OK` 表示文件与提供的校验值一致。请从本仓库的 Release 页面获取文件。

</details>

## 在本机完成

截图、录屏和 OCR 在本机处理，无需账号，不依赖自建云端。历史记录可选开启；系统分享的去向由你选择。屏幕和麦克风使用 macOS 系统权限管理。

**目前未提供** Intel / Windows / iOS 版本、GIF 录制、摄像头画中画、视频剪辑、视频背景美化及云端分享链接。这里展示的是当前功能；需求中的后续规划不代表已经实现。

## 为开发者准备

SwiftUI + AppKit 原生界面，ScreenCaptureKit 采集，Vision OCR，AVFoundation 音视频处理。**没有外部 Swift 包依赖。**

需要 Apple 芯片 Mac、Swift 6 和 Command Line Tools 或 Xcode：

```sh
git clone https://github.com/why-evolving/capture.git
cd capture
zsh scripts/test.sh
swift build -c release
```

生成可运行的 `.app`，先在自己的 Mac 上准备并固定自己的本地签名：

```sh
python3 scripts/signing.py setup
zsh scripts/build.sh .build/release-candidate
open .build/release-candidate/Capture.app
```

签名准备可能需要钥匙串确认。详细环境、验证方式和贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

| 深入了解 | 入口 |
| --- | --- |
| 产品与交互 | [需求](docs/product/requirements.md) · [UI 规范](docs/design/ui-spec.md) |
| 工程与验证 | [技术方案](docs/engineering/technical-design.md) · [测试方案](docs/testing/test-plan.md) · [CI](https://github.com/why-evolving/capture/actions) |
| 发布与协作 | [更新记录](CHANGELOG.md) · [安装与分发](docs/distribution.md) · [报告问题](https://github.com/why-evolving/capture/issues) |
| 安全与来源 | [安全政策](SECURITY.md) · [第三方说明](THIRD_PARTY_NOTICES.md) · [展示图来源](docs/assets/readme/README.md) |

报告问题请使用应用生成的示例内容，不要上传个人截图、录屏、密钥或含未遮挡原图的项目。项目按尽力原则维护，欢迎问题反馈与改进贡献。

## 开源许可

[**AGPL-3.0-only**](LICENSE)。允许商业使用与收费出售；分发受覆盖程序须按协议提供对应源码，修改版通过网络供用户交互时还适用第 13 条。详见[中文许可说明](LICENSE.zh-CN.md)及[版权通知](NOTICE)。

---

<p align="center"><sub>Capture · Native macOS · 截图与录屏，都留在你手里。</sub></p>
