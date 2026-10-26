# Capture

原生macOS截图与本地录屏工具。

**采用 AGPL-3.0-only 授权，允许商用和收费出售。分发受覆盖程序时须按协议提供对应源码；修改版通过网络供用户交互时还适用第13条。** 详见[LICENSE](LICENSE)、[中文说明](LICENSE.zh-CN.md)及[版权通知](NOTICE)。

## 功能

- 区域、窗口、全屏、滚动截图；冻结选取画面，可切换快速与调整后确认。
- 渐变/图片背景、留白、圆角、阴影、窗口装饰、命名预设及自动应用。
- 标注、遮挡、裁剪、OCR、拼图、置顶、可编辑项目和可选本地历史。
- MP4录屏，独立快捷键，电脑声音/麦克风分别配置，暂停继续与预览保存。
- 录屏可松手倒计时，也可保留选框移动/缩放后回车开始。

声明最低macOS14，面向Apple芯片Mac。Intel、Windows、iOS、GIF和高级视频编辑未提供。支持范围以实际验证为准。

## 构建

需要Swift6及Command Line Tools或Xcode。不依赖外部Swift包，不需要维护者私钥。

```sh
zsh scripts/test.sh
swift build -c release
```

生成.app时，在自己的Mac上准备自己的固定本地签名，再构建：

```sh
python3 scripts/signing.py setup
zsh scripts/build.sh .build/release-candidate
open .build/release-candidate/Capture.app
```

签名准备可能需要系统钥匙串确认。构建不会替换正在运行的应用。当前不提供已公证的安装包；系统授权由运行者自行授予。

## 文档与贡献

[文档](docs/README.md) · [构建与贡献](CONTRIBUTING.md) · [来源](THIRD_PARTY_NOTICES.md) · [安全](SECURITY.md)

应用在本机处理截图、录屏和OCR，系统分享由使用者选择目标。报告问题只用生成的示例内容，不上传个人截图、录屏、密钥或含未遮挡原图的.capture项目。项目按尽力原则维护。
