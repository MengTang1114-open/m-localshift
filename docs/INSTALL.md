# 安装 LocalShift

要求：Apple 芯片（M1 及以后）的 Mac，macOS 13 或更新。

1. 打开 `LocalShift-<版本>.dmg`，把 **LocalShift** 拖进「应用程序」文件夹。
2. 在「应用程序」里双击 LocalShift。第一次会提示"无法验证开发者"，这是因为它没有在 Apple 登记，并不是有问题。按你的系统版本放行：
   - **macOS 15 及以后**：在提示框里点「完成」。打开「系统设置 → 隐私与安全性」，翻到最下面，点「仍要打开」，输入开机密码，再点「打开」。
   - **macOS 13、14**：在「应用程序」里右键点 LocalShift，选「打开」，再点「打开」。
3. 如果提示"已损坏，无法打开"：打开「终端」，粘贴下面这行并回车，然后再双击：

   ```
   xattr -dr com.apple.quarantine /Applications/LocalShift.app
   ```

只需要放行一次。

## 首次使用时的系统权限

- **转换 Pages 文件**：会询问是否允许 LocalShift 控制 Pages，点「允许」。没有安装 Pages 的话，Pages 相关转换不可用，其他功能不受影响。

LocalShift 不联网、不上传文件，所有处理都在你的 Mac 上完成。
