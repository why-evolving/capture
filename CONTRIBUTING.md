# 构建与贡献

本项目采用AGPL-3.0-only。提交贡献前阅读LICENSE、NOTICE及中文说明；贡献者保留版权，并按AGPL-3.0-only提供贡献，不要求转让版权。不得引入不兼容授权或无法核实来源的代码/素材，不另行附加禁止商用或闭源分发许可。

```sh
python3 scripts/check-docs.py
python3 scripts/check-publication.py
python3 scripts/check-native-report.py --self-test
zsh scripts/test.sh
swift build -c release
```

普通CI只运行上述无凭据检查，不更改系统授权或采集桌面。生成.app时在自己的Mac上执行python3 scripts/signing.py setup，再执行zsh scripts/build.sh .build/release-candidate；始终保管自己的签名，不取得维护者私钥。默认通用ID为local.capture.app；已有开发者使用本地identity配置中的固定ID。可显式用CAPTURE_BUNDLE_ID选择构建ID。

原生自检使用生成内容、隔离配置/库和私有剪贴板。通过LaunchServices启动后，仍须用check-native-report.py校验实际报告；锁屏、拒绝或跳过不是通过。真实登录项测试必须显式给出CAPTURE_INSTALLED_APP的稳定安装绝对路径，不在CI执行。

请给出可复现步骤、相关测试、验证范围及变更说明。提交前git diff --check；不上传私人截图、录屏、.capture原图、配置、日志、令牌或签名材料。
