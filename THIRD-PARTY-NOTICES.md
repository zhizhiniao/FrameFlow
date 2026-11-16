# 第三方组件与源码

本便携包通过独立进程使用下列组件，保留各组件自己的许可；不改变上游许可。

|组件|本次版本|许可/来源|
|---|---|---|
|yt-dlp Windows 独立程序|2026.08.19|独立程序含 GPLv3+ 组件；源码 https://github.com/yt-dlp/yt-dlp/tree/2026.08.19 ，随包许可见 licenses|
|FFmpeg / ffprobe Gyan essentials|8.0|该构建启用了 GPL/version3；许可、构建参数见 licenses/FFmpeg-*；构建来源 https://www.gyan.dev/ffmpeg/builds/ ，FFmpeg 源码 https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz|
|Python|3.12.10|PSF；https://www.python.org/downloads/release/python-31210/ ，许可见 licenses|
|Playwright Python|1.62.0|Apache-2.0；https://github.com/microsoft/playwright-python/tree/v1.62.0|
|Chromium|Playwright 配套构建|Chromium BSD 及第三方许可，随 browser 目录保留；https://www.chromium.org/Home/|
|Node.js|Playwright 随附版本|MIT 及第三方许可；worker/_internal/playwright/driver/LICENSE|
|greenlet / pyee|见构建依赖清单|对应许可证见 licenses|
|PyInstaller 引导程序|6.22.3|GPL-2.0-or-later with bootloader exception；https://pyinstaller.org/en/stable/license.html|

帧流新增的 worker 与启动器源码在 `source`，界面源码为旁边的 `.ps1`、`.xaml`、`.cs`。
本包中的第三方程序按各自许可分发；原创界面与工具代码不改变第三方许可。对应源码链接列于上表；Gyan FFmpeg 构建配置随 licenses/FFmpeg-build.txt 提供，构建配方入口：https://github.com/GyanD/codexffmpeg 。
# 0.2.2 新增依赖

CookieCloud 客户端使用 PyCryptodome（pycryptodomex 3.23.0）完成本地 AES 解密；许可见 `licenses/PyCryptodome-LICENSE.rst`。协议参考 https://github.com/easychen/CookieCloud ，不包含用户同步凭据或 Cookie 数据。


YouTube 登录使用 Patchright Python 1.58.2（Apache-2.0，https://github.com/Kaliiiiiiiiii-Vinyzu/patchright-python）；优先启动系统 Chrome/Edge 的独立资料目录。其他平台仍使用 Playwright。
