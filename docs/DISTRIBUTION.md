# 发布与分发

决定（2026-10-30）：以 GPLv3 开源；安装包发在本仓库的 GitHub Releases；不上 App Store。

## 现在：未签名版本，直接发安装包

App 只有本机临时签名。对方第一次打开时 macOS 会拦一次，按 [INSTALL.md](INSTALL.md) 放行后就能正常用。适合发给熟人。

发版步骤：
1. 在准备好运行库的 Mac 上跑 `tools/verify_release.sh`，全部通过。
2. 改 build.sh 顶部的版本号，更新 CHANGELOG.md。
3. `./build.sh`，然后 `tools/make_dmg.sh` 打出 `LocalShift-<版本>.dmg` 和 sha256。
4. 在 GitHub 上新建 Release（tag `v<版本>`），附 DMG 和 sha256，正文写本版更新和 INSTALL.md 的链接。

## 以后：开发者签名和公证（让陌生人也能顺利安装）

需要 Apple Developer Program（国区 688 元/年）。**这和 App Store 无关**，不用上架、不用审核，只是让 macOS 认得这个 App，下载后双击即可打开。

1. 申请 Developer ID Application 证书。
2. 按"由内到外"的顺序签名：先签 FFmpeg、Python、LibreOffice 里的每个可执行文件和动态库，最后签 App；都带 `--options runtime --timestamp`。
3. 开启 hardened runtime 后需要的 entitlements：
   - `com.apple.security.automation.apple-events`（控制 Pages）
   - 随包 Python / LibreOffice 可能还需要 `com.apple.security.cs.allow-unsigned-executable-memory`、`com.apple.security.cs.disable-library-validation`，以实测为准，尽量少开
4. 签 DMG → `xcrun notarytool submit --wait` → `xcrun stapler staple`。
5. 在一台干净的 Mac（最好 macOS 13）上从下载开始装一遍。

证书和公证密码放 GitHub Secrets 后，第 2–4 步可以做成打 tag 自动执行的工作流。

## 第三方许可证

| 组件 | 许可证 | 分发时要做的 |
| --- | --- | --- |
| FFmpeg 9.0.2（Martin Riedl 静态构建） | GPLv3+ | 附许可证；提供该构建的完整对应源码（每个 Release 的说明里写明源码获取地址） |
| LibreOffice | MPL 2.0 | 附许可证；注明源码获取地址 |
| Python 及 Pillow、lxml、python-docx、openpyxl、pypdf、reportlab | PSF / 各自宽松许可证 | 附许可证 |
| libwebp | BSD | 附许可证 |

LocalShift 自己的代码以 GPLv3 发布（见仓库根目录 LICENSE）。随包运行库的许可证放在 `Contents/Resources/Licenses/`。
