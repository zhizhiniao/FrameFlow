# 自动更新与发版

## 用户会收到什么

- 从 **0.3.0** 开始，打开软件约 12 秒后自动检查 GitHub 最新正式版本，运行中每 4 小时复查。
- 发现新版后自动在后台下载完整更新包，不阻塞下载工作区。底部显示“新版已准备好”，点“更新并重启”完成升级。
- 正在下载或登录时不会强制重启。检查失败会提示，并在约 15 分钟后自动重试，也可以点“检查更新”。
- 未运行、离线或无法连接 GitHub 的用户，恢复运行与联网后才能收到更新。**0.2.x 没有更新器，需要先手动安装一次 0.3.0。**

## 更新保护

- 更新源固定为 `zhizhiniao/FrameFlow` 的 GitHub 正式 Release；草稿、预发布、相同或更旧版本不安装。
- 只接受该仓库同一版本的约定 ZIP 名称与 HTTPS 下载地址；下载大小及 GitHub `sha256:` 元数据必须匹配。
- 解压前检查越界路径、重复路径、符号链接、文件数和总大小；解压后核对清单中每个文件的大小及 SHA-256。
- 更新助手等待窗口和启动器退出，再替换清单内程序文件；保留用户额外放入程序目录的文件，文件替换失败则回退已改文件。
- 登录态、设置默认位于 `%LOCALAPPDATA%/FrameFlow`，视频默认在系统“视频/帧流”；更新缓存与回退记录在前者的 `updates` 下。
- SHA-256 验证完整性，不等同于 Windows 代码签名。不要改用不明镜像更新源。

## 作者以后怎样发新版

1. 修改功能并运行 `powershell -NoProfile -File tests/Update.Check.ps1` 及与改动相应的测试。
2. 把 `app-version.json` 的版本改为新的 `x.y.z`，更新 `docs/RELEASE-NOTES.md`，提交并推送 GitHub。
3. 运行 `powershell -NoProfile -File tools/Package-Release.ps1 -Version 0.3.1 -RuntimeDirectory "上一版完整便携目录" -Publish`。
4. 确认正式 Release 包与 SHA256SUMS 上传成功。更新器只读取最新正式 Release；**只推代码或发预发布不会推送更新。**

构建脚本复制指定运行时，打入当前界面、更新器与源码；下载引擎有修改时须先重建 Worker，再把新运行时传给打包脚本。
每个版本使用新版本号，不覆盖已经发布的 ZIP。撤回有缺陷版本后，发布更高版本号的修复版。

接口依据：[GitHub Release API](https://docs.github.com/en/rest/releases/releases)、[Release asset digest](https://docs.github.com/en/rest/releases/assets)。
