# 代码结构

一个 macOS App（SwiftUI + AppKit），单个 Swift 模块，外加随包的 Python 辅助程序和第三方运行库。

## 一次转换怎么走

```
界面（Interface / RadialOverlay / ToolEditors）
   │  文件列表 + 操作 ID（如 "format_png"、"trimVideo"）+ ConversionSettings
   ▼
ConverterEngine.convert           EngineRouter.swift
   │  校验输入和参数 → 建临时工作区 → 按类别分派
   ▼
AdvancedNative   图片、PDF 页面操作（ImageIO / PDFKit / CoreImage / Vision）
AdvancedMedia    音视频（随包 FFmpeg / ffprobe）
OfficeEngine     文档、表格、演示、电子书、归档、SVG（office-helper.py、LibreOffice、Pages）
SubtitleEngine   SRT / VTT / TXT 字幕
   │  只往临时工作区写结果
   ▼
ConverterEngine 检查结果确实在工作区内 → 复制到目标文件夹（重名自动编号，失败回滚）
```

子进程全部经过 `OperationContext.run`：统一处理取消、超时、日志上限和子进程组清理。

## 文件地图

| 文件 | 职责 |
| --- | --- |
| `AppMain.swift` | 入口、菜单栏、命令行参数（截图、`--verify-ui` 自检） |
| `Interface.swift` | `AppModel`（界面状态）、历史记录、主窗口各视图 |
| `ToolEditors.swift` | 26 个工具的编辑面板（画布、时间轴、PDF 页面整理） |
| `RadialOverlay.swift` | 轮盘绘制、Finder 拖动监听（`DragWheelMonitor`）、配色 |
| `FloatShelf.swift` | 暂存架窗口、修饰键设置 |
| `EngineTypes.swift` | 共享类型：类别、选项、`ConversionSettings`、错误 |
| `CapabilityCatalog.swift` | 每种输入能转成什么、能用哪些工具（唯一来源） |
| `EngineRouter.swift` | `ConverterEngine`：校验、分派、发布结果 |
| `OperationContext.swift` | 子进程执行、取消、运行库查找 |
| `AdvancedNative.swift` / `AdvancedMedia.swift` / `OfficeEngine.swift` / `SubtitleEngine.swift` | 各引擎（见上） |
| `FileTransfer.swift` | "移动到文件夹"操作，失败整体回滚 |
| `Resources/office-helper.py` | Office/EPUB/归档的结构化读写 |
| `Resources/OfficePages.applescript` | 通过 Pages 导入导出 |

## 怎么扩展

**加一个转换方向**：
1. `CapabilityCatalog.formats` 加上目标格式，`docs/conversion-matrix.json` 同步（单元测试会比对两者）。
2. 在对应引擎里实现；结果只写进传入的 `scratch` 目录。
3. 在 `Tests/Functional` 或 `Tests/Acceptance` 加真实样本的回读检查。

**加一个工具**：
1. `CapabilityCatalog.tools` 和 `options(for:mode:)` 里登记 ID。
2. 需要的参数加到 `ConversionSettings`（后续计划拆成每个工具独立的参数类型，见 ROADMAP）。
3. 在 `ToolEditors.swift` 加编辑面板，在引擎里实现。

## 测试分层

| 层 | 位置 | 在哪跑 |
| --- | --- | --- |
| 单元测试 | `Tests/Unit`（`swift test`） | CI、任何 Mac |
| 验收程序能否编译 | `tools/check_harnesses.sh` | CI |
| 真实转换回归 | `test.sh`、`Tests/Functional` | 准备好运行库的 Mac |
| 完整发版门禁 | `tools/verify_release.sh` + `Tests/Acceptance` | 准备好运行库的 Mac，发版前必跑 |
| 界面截图（浅色/深色） | `tools/screenshots.sh` | CI 的 Screenshots 工作流，手动触发（Actions → Screenshots → Run workflow，选 PR 分支） |

## 外观

- 颜色只用系统语义色（`Theme`、`LSPaint`），跟随浅色/深色模式和系统强调色；强调色只给主按钮和选中的花瓣。
- 面板用 `.glassCard()`（系统材质加顶部亮边），侧栏用 `LSMaterial(.sidebar)`。不要再写死白色或灰色。
- 图标由 `tools/make_icon.py` 生成 `Assets/AppIcon.icns`（Linux 上也能跑）；`LSIcon.appMark` 用同一套几何，改一边要同步另一边。
