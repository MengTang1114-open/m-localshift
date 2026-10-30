# LocalShift 本机工程验收

负责人执行实现、真实转换、独立内容回读和相关复测。用户无需承担工程验收。

主入口：

```sh
bash tools/verify_release.sh "$PWD/work/release-audit/final-$(date -u +%Y%m%dT%H%M%SZ)"
```

依赖：macOS arm64、Xcode Command Line Tools、本项目完整签名运行库、Poppler，以及配置的测试 Python（Pillow、python-docx、python-pptx、openpyxl、pypdf、reportlab）。验收使用 work/functional 中已准备的45类真实输入及工作项，work/release-audit 中的边界和损坏输入；生成器为 tools/make_fixtures.py、Tests/Acceptance/make_fixtures.py。输出目录必须不存在，证据不会混用旧输出；功能测试二进制保存在该次验收目录中。

主门禁构建同一个应用，执行基础回归、275方向、32工具用例、独立语义回读、多语种/多表/高精度样本、拒绝与回滚、顽固子进程清理、真实原生界面和落点集成；在拒绝网络的进程环境重跑Office边界样本，最后校验全包字节、运行后签名、源码与资源一致性及覆盖数量。构建或基础编译失败即停止；独立阶段失败会继续收集其余结果，任一失败都不生成 complete.json。

补充内容套件（Pages 专项必须与主门禁串行，避免共享 Pages 会话互相干扰；各输出名均须全新）：

```sh
bash Tests/Acceptance/media-fixes/run.sh fresh-phase-name
bash Tests/Acceptance/multipage-image/run.sh fresh-phase-name
PYTHONDONTWRITEBYTECODE=1 "${LOCALSHIFT_TEST_PYTHON:-python3}" Tests/Acceptance/media-fixes/stereo.py fresh-phase-name
bash Tests/Acceptance/office-fixes/svg-size/rerun.sh "$PWD/LocalShift.app/Contents/Resources" "$PWD/work/release-audit/office-fixes/svg-size/fresh-phase-name"
bash Tests/Acceptance/office-fixes/pages-recovery/rerun.sh "$PWD/LocalShift.app/Contents/Resources" "$PWD/work/release-audit/office-fixes/pages-recovery/fresh-phase-name"
```

media-fixes 对实际像素覆盖、显示比例、音轨数/声道内容/时序和GIF逐帧回读；multipage-image 对TIFF每页颜色、OCR、尺寸、次序和显式拒绝回读；office-fixes/svg-size共100项，覆盖DOCX结构、UTF16 EPUB、OCR、SVG尺寸、中文顺序、多表、精度打印和PDF方向/DPI；pages-recovery共32项，覆盖全部Pages方向、连续转换、609/其他错误、导出后未知回执与已打开时取消清理。测试只处理本任务文稿，不退出Pages。

落点集成测试向生产NSDraggingDestination提供NSDraggingInfo，实际调用轮盘、控制器、AppModel和引擎生成PDF。它不等价于物理Finder按住修饰键拖动；当前自动化API无法可靠表达该原子手势。AirDrop 跨设备接收和 macOS 13 真机尚未验证，不计作通过。
