# 微信视频号组件来源与构建

`wechat/FrameFlow.Wechat.exe` 是独立的 GPL-3.0 组件；对应完整引擎源码为随包 `source/wechat_capture.py`。
MP4 文件头恢复与内存扫描方案改写自 [laoyu20032003/wx_video_downloader](https://github.com/laoyu20032003/wx_video_downloader)，固定提交 `6785dccc8d0243176bd2ece36ad596c989b751d7` 的 `MemScan.cs`、`wx-dl.ps1`。
修改包括：Python 标准库实现、自动进程发现、开始时建立基线、增量抓取、部分媒体预览、文件头缓存、固定清晰度、JSON 接口、取消与完整验证。保留 GPL-3.0；全文见 `licenses/WechatCapture-GPL-3.0.txt`。

构建：Windows x64、Python 3.12、PyInstaller 6.22.3；`tools/Build-Wechat.ps1` 提供精确命令。
在源码目录执行 `.build-venv/Scripts/python.exe -m PyInstaller --noconfirm --clean --onefile --name FrameFlow.Wechat wechat_capture.py` 也可独立构建。
运行依赖随帧流提供的 FFmpeg / ffprobe；无需安装第三方 Python 包、代理证书或驱动。

帧流原创界面保留原 MIT 标注；本组件不改标为 MIT。发行包不附带用户媒体、文件头或短期签名 URL。

## 使用与边界

进入「微信视频号」后点击「开始抓取」，等状态提示就绪，再在电脑版微信打开并播放一条新视频。
候选封面在右侧出现后自行核对，再点击左侧「下载所选视频」。微信预加载内容也可能进入候选，不自动猜选。
抓取会读取少量媒体用于预览；完整下载只在确认后开始。文件通过完整解码才进入媒体库。
切换回「链接下载」会停止抓取；已提交的下载继续。关闭帧流会结束抓取和未完成下载。

仅在本机点击开始后读取微信媒体进程，提取媒体 URL 与必要 MP4 文件头。短期数据位于 `%LOCALAPPDATA%/FrameFlow/wechat/sessions`，不上传。
微信未运行、没有解密文件头、地址过期或不支持的媒体格式时会提示重播；首版不承诺所有账号、所有微信版本或直播可用。
