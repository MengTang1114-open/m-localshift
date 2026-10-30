# LocalShift 维护规则

人和 Agent 都按这份规则维护。开工先读 HANDOFF.md（当前状态）和 docs/ARCHITECTURE.md（代码地图）。

## 产品边界

- 本地优先：不上传文件、不联网、不加遥测；转换不覆盖原文件；移动文件前明确确认。
- 功能保持简洁：新功能先问"多数用户会不会用"，不为凑数量加入口。新增转换方向或工具，要同时补测试和文档。
- 界面、命名、图标、文案都用自己的设计，不照搬其他产品。

## 工作流程

- main 只接受 PR，只快进；每个 PR 只做一件事，CI 必须通过。
- 改了引擎行为（转换结果会变）的 PR，合并前要在准备好运行库的 Mac 上跑 `tools/verify_release.sh`，或者在 PR 里写明还没跑、由谁补跑。
- 发布由人决定，流程见 docs/DISTRIBUTION.md。Agent 不发布、不对外发言。
- 版本号在 build.sh 顶部；改版本时同时更新 CHANGELOG.md。

## 代码约定

- Package.swift 是唯一的编译定义；不要在别处另写一份源文件列表（验收测试程序除外，它们由 tools/check_harnesses.sh 在 CI 里守住）。
- 打包后的 App 只用随包运行库（`OperationContext.executable`）；开发机路径和 Homebrew 只能作为开发回退，不能写进 App 的查找顺序。
- 子进程一律走 `OperationContext.run`，以便取消、超时和清理子进程。
- 引擎只往调用方给的临时目录写文件，由 `ConverterEngine.convert` 统一发布到目标位置。
- 新代码一行一个语句，不用分号把多句挤在一行；旧代码改到哪里顺手整理到哪里。

## 文档分工

- README.md：给用户和新开发者看，说清是什么、怎么用、怎么构建。
- HANDOFF.md：当前状态，覆盖写，不超过 10 行。
- CHANGELOG.md：每个版本改了什么。
- docs/GOTCHA.md：技术上踩过的坑，按主题合并，不写流水账。
- docs/ROADMAP.md：排好优先级的待办。
