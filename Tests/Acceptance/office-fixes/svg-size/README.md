# Office 内容与 SVG / PDF 尺寸专项验收

在项目根运行（输出目录必须尚不存在）：

```bash
bash Tests/Acceptance/office-fixes/svg-size/rerun.sh \
  "$PWD/LocalShift.app/Contents/Resources" \
  "$PWD/work/release-audit/office-fixes/svg-size/leader-final-app"
```

脚本使用给定的同一 App 资源目录中的 Python、LibreOffice 和 helper，独立编译实际 `OfficeEngine.swift`、`AdvancedNative.swift`、`OperationContext.swift`（不构建或启动 App），只向新证据目录写文件。源码 hash 保存在 `compiled-source-sha256.txt`。可用 `LOCALSHIFT_TEST_PYTHON` 指定兼容 Python；`LOCALSHIFT_TEST_MODULE_CACHE` 可指定本任务已有的模块缓存，否则使用新证据目录内的缓存。

预期 100 项：helper 15、原生/扫描/混合 PDF 可编辑 Office 9、新内容 oracle 76。其中新 oracle 覆盖 SVG 27、rich PDF 中文顺序及 RTL/竖排 5、工作表 CSV/TSV 与生成表格 PDF 11、PDF 300 DPI/旋转/非零 mediaBox/多页/安全上限和普通 Office 144 DPI 17、SVG 安全与分数单位 16。输出报告分别为 `helper/helper-results.json`、`engine/regression/content-results.json`、`content-results.json`。

SVG：无单位和 px 按 CSS 像素，绝对单位按 96px/in 换算。viewBox-only 独立导出采用一 viewBox 单位一 CSS 像素；只有一个绝对尺寸时从 viewBox 比例推导另一个尺寸。分数像素向上取整，PDF 保留未取整的 72/96 点画布。百分比、字体单位、计算表达式及样式表尺寸需要先展开为根元素绝对尺寸；不会猜测浏览器宿主的外部布局。输出 PNG/JPEG 校验 96 DPI，其他格式按容器可用能力保留信息。

PDF：原始 PDF 的 PNG/JPG 使用 300 DPI，普通 Office/Slides 中间 PDF 转图为 144 DPI。90/270 度按显示方向交换宽高，并核对实际色块位置；非零页框有独立样本。单页上限 16384 边长/一亿像素，页数上限 10000。13 页 Letter 样本总计 109395000 像素，检查全部页数、顺序与独立页色标；高像素拒绝样本仅一页，因此测试不会分配超限图像。

CJK：只对含中日韩文字、水平行且原生字形坐标退化或折返的行尝试 OCR。只在同位置 OCR 与原生行去空白后的字符多重集完全一致时采纳可视顺序；不插入、删除、替换原生字符。常见 RTL 文字和竖排控制保持原输出；OCR 不确定时保留原生内容，不保证修复所有字体编码问题。

工作表：XLSX/XLS/ODS 的所有表按顺序分别返回；单表仍保持单个 `*-converted` 文件，多表带序号和安全表名。含路径/控制字符的 OOXML 工作表名会在 CSV 导出前拒绝，避免路径注入；不会输出部分表冒充全表。新生成 XLSX 的列宽和换行帮助保留 CSV 文字及打印内容，既有工作簿的打印版式不改动。非常长的单个单元格仍受 Excel 列宽/行高上限影响。

PDF 页面导出约定：全部页面、300 DPI。单位依据：[CSS absolute lengths](https://www.w3.org/TR/css-values-4/#absolute-lengths)、[SVG intrinsic sizing](https://www.w3.org/TR/SVG2/coords.html#IntrinsicSizing)。全表 CSV 依据：[LibreOffice CSV filter token 12](https://help.libreoffice.org/latest/en-US/text/shared/guide/csv_params.html)。

运行边界：此脚本验证独立引擎与实际 App 资源；生产路由和最终 App 的签名、打包、交互由 tools/verify_release.sh 验收。
