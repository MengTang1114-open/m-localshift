# 路线图

按顺序做。每条一个 PR，CI 通过；动到引擎行为的，合并前在 Mac 上跑 `tools/verify_release.sh`。这里只列功能和工程；外观的约定见 docs/ARCHITECTURE.md「外观」。

## P0 能稳定地打出安装包

1. **macOS 13 真机验证**。

## P1 降低维护成本

2. **操作 ID 类型化**：`"format_png"` 这类字符串改成 `enum Operation`，别名表只留在界面入口。
3. **拆分 `ConversionSettings`**：每个工具一个参数结构体。
4. **拆大文件**：`Interface.swift`、`ToolEditors.swift` 按职责拆开。
5. **代码格式**：引入 swift-format 并在 CI 检查。

## P2 功能体验

6. 签名公证就绪后再接自动更新（Sparkle）。
