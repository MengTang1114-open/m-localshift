# Pages 受控恢复验收

在项目根运行，输出目录必须不存在：

```bash
bash Tests/Acceptance/office-fixes/pages-recovery/rerun.sh \
  "$PWD/LocalShift.app/Contents/Resources" \
  "$PWD/work/release-audit/office-fixes/pages-recovery/leader-final-app"
```

共 32 项：规格中全部 16 个涉及 Pages 的方向、6 次连续转换、6 个私有脚本故障注入、无关 canary 打开/存活/所有本轮 UUID 文稿已关闭三项，加一项确定性取消。每个新 Pages 文件再实际导出 TXT 并检查正文；直接文档导出检查内容，图片检查非空画面。PDF 文本使用稳定正文 `conversion`、`editable text`、`123` 标记：当前 Pages 原生 PDF 的 ft 连字在 pypdf 中可被映射为 `)`，不能据此把可见标题判断为转换失败。

私有故障脚本只从给定资源目录读取生产 AppleScript 并在测试副本中注入，不更改共享 App：导出前一次 -609、导出完成但回执 -609、关闭 -609、持续 -609、导出前 -2700、导出后 -2700；取消测试在文稿已定位、导出前阻塞时触发。独立短超时清理必须在取消返回前关闭本次文稿，且不启动或终止 Pages。检查转换次数/导出次数及 canonical 输出是否存在；只有 -609 恢复可成功，其他错误不能发布文件。暂存文件全部位于本任务 UUID 目录，保存后的文稿名仍保留 UUID。测试另建独立 canary 文稿，最终仅关闭此 canary；不关闭预先存在的文稿、不退出或终止 Pages。

脚本全程设置 `PYTHONDONTWRITEBYTECODE=1`，只在新证据目录生成二进制、私有脚本及输出。`LOCALSHIFT_TEST_MODULE_CACHE` 可复用本任务的 Swift 系统模块缓存；默认缓存也在新证据目录。编译源码及给定 App 资源的 hash 写入 `compiled-source-sha256.txt`。此测试独立调用 OfficeEngine，生产路由/签名/矩阵由负责人统一验证。
