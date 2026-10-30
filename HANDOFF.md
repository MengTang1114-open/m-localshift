# 交接

- 2026-10-30：0.3.0（build 4）以 GPLv3 开源并发布到 GitHub Releases。DMG 在 macOS 26.2 / Apple M5 上构建，verify_release.sh 全部通过（回归 58、矩阵 275、工具 32、离线 21、原生界面 31、访达拖放 19）。sha256 b3a74fd1…391a。
- 已知：`tools/screenshots.sh` 的 --snapshot 用 cacheDisplay，轮盘和说明正文会是黑的，系统为深色时浅色/深色两张相同；README 截图用的是窗口抓图。只有 Command Line Tools 的机器跑不了 `swift test`（缺 XCTest），以 CI 为准。
- ⌃ 操作轮盘已去掉，六项操作的代码还在、没有入口，待清理。
- 还没验：macOS 13 真机；Pages 授权点「不允许」后的提示；从网上下载后的首次放行流程。
- 下一步见 docs/ROADMAP.md。
