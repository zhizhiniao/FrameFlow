<p align="center"><img src="assets/brand.png" width="120" alt="帧流 FrameFlow Logo" /></p>

# 帧流 FrameFlow

**把值得留存的视频，保存到自己的媒体库。——蒋啊讲出品**

Windows 本地视频与图文下载工具。粘贴链接或分享文案，在本地视频库搜索、播放和管理；支持多个下载任务并保留各平台独立登录资料。

[下载最新版](https://github.com/zhizhiniao/FrameFlow/releases/latest) · [自动更新说明](docs/AUTO-UPDATE.md) · [反馈问题](https://github.com/zhizhiniao/FrameFlow/issues)

## 开始使用

1. 从 Releases 下载最新 `FrameFlow-Portable-v版本号-Windows-x64.zip`，完整解压到有写入权限的目录。
2. 双击 `FrameFlow.exe`，粘贴视频链接或完整分享文案，点击“开始下载”。
3. 需要账号时使用软件的平台登录入口；从右侧视频库搜索、播放或打开文件目录。

支持 Windows 10/11 x64；便携包含运行时，无需自行安装 Python、Node 或 FFmpeg。未做代码签名，请核对下载来源与 SHA256SUMS。

## 自动更新

**从 0.3.0 开始默认开启：启动自动检查 → 后台下载并校验 → 提示“更新并重启”。**

运行中每 4 小时复查；网络失败约 15 分钟后重试。更新不会在下载或登录过程中强制重启。
以后作者发布更高版本的 GitHub **正式 Release**，已安装此版且能连接 GitHub 的用户即可收到提示；只推送代码或预发布不会触发。
旧 0.2.x 版本需要先手动下载 0.3.0 一次。离线、软件未运行或 GitHub 无法连接时，需恢复运行与联网后才能检查。

更新包经过大小、SHA-256 和逐文件清单校验，安装失败回退。完整机制和作者发版命令见 [自动更新与发版](docs/AUTO-UPDATE.md)。

## 下载与媒体库

| 内容来源 | 使用说明 |
|---|---|
| YouTube、哔哩哔哩、X、TikTok | 粘贴视频链接；需要时使用独立登录窗口 |
| 抖音、小红书 | 支持分享链接及相应图文流程，按平台要求登录 |
| 微信公众号 | 保存文章图文；不是微信视频号通用下载器 |
| 光厂片场 | 支持案例详情页的公开播放版 |

仅保存自己有权访问和使用的内容，不解除会员、付费或地区限制。平台登录成功不等于每条链接都能下载；实际能力受平台和网络变化影响。

## 文件与升级

- 默认视频目录：Windows“视频/帧流”，可以在软件内修改。
- 登录态与设置：`%LOCALAPPDATA%/FrameFlow`，每位用户自行登录。
- 更新器只替换清单内程序文件；用户媒体和登录资料不打入发布包。
- 本地删除文件是永久删除，执行前软件会确认。

## 开发与测试

界面使用 Windows PowerShell 5.1/WPF；下载 Worker 使用 Python、Playwright/Patchright 和 yt-dlp。原始源码可直接查看 `.ps1`、`.xaml`、`.cs` 和 `.py` 文件。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Update.Check.ps1
powershell -NoProfile -File tools/Package-Release.ps1 -Version 0.3.1 -RuntimeDirectory "上一版完整便携目录" -Publish
```

构建下载引擎的依赖见 `requirements-build.txt`；完整环境构建见 `tools/Build-Portable.ps1`。个人登录资料、媒体、运行日志和历史验收样本不属于源码仓库。

## 联系作者

有使用问题、建议或想交流个人创作工具，可以扫码添加微信，备注“帧流”。

<img src="docs/images/wechat-contact.png" alt="蒋啊讲的个人微信二维码" width="300" />

公众号：**知鸟PLAN** · 微信：**aizzn2030**

## 许可

原创帧流代码采用 MIT；第三方组件各自保留原许可，完整清单及对应源码入口见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。不把整个便携包声明为纯 MIT。
