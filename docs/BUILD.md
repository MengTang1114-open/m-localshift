# 构建

需要：Apple 芯片的 Mac，Xcode Command Line Tools（`xcode-select --install`）。

## 只改代码

```bash
swift build
swift test
```

不需要任何运行库。转换功能会退回使用系统里装的 FFmpeg 等（只在开发构建里允许）。

## 打完整的 App 和安装包

```bash
python3 tools/bootstrap_runtime.py   # 第一次约下载 330 MB，之后用缓存
./build.sh                           # 生成 LocalShift.app
tools/make_dmg.sh                    # 生成 dist/LocalShift-<版本>.dmg 和 sha256
```

`bootstrap_runtime.py` 按 [tools/runtime.lock.json](../tools/runtime.lock.json) 下载固定版本并校验 sha256，准备到 `.runtime/`：

| 组件 | 来源 | 用途 |
| --- | --- | --- |
| FFmpeg / ffprobe 9.0.2 | Martin Riedl 静态 arm64 构建 | 音视频；`work/vendor/ffmpeg-9.0.2/verify-runtime.py` 会逐项检查编码器、滤镜和真实编码 |
| Python 3.12 | python-build-standalone | 运行 `Resources/office-helper.py` |
| python-docx、openpyxl、Pillow、reportlab、pypdf、lxml 等 | PyPI wheel | Office/PDF/图片处理 |
| libwebp | 取自 Pillow wheel | Swift 引擎的 WebP 编码 |
| LibreOffice | 官方 arm64 安装包 | 文档、表格、演示转换 |

`build.sh` 每次都从空目录组装 App，再调用 `tools/bundle_runtime.py` 把 `.runtime/` 复制进去。只想快速看界面时可以 `LOCALSHIFT_SKIP_RUNTIME=1 ./build.sh`，打出的 App 不带运行库。

## 升级某个运行库

1. 改 `tools/runtime.lock.json` 里的地址和 sha256（只选发布至少两周的版本）。
2. 重新跑 `bootstrap_runtime.py` 和 `build.sh`。
3. 开 PR，CI 的 Runtime 工作流会自动打完整 App 并跑真实转换回归；合并前再在 Mac 上跑 `tools/verify_release.sh`。

## 版本号

在 `build.sh` 顶部；改版本时同步更新 CHANGELOG.md。
