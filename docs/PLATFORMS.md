# 下载平台与验证范围

0.3.6，2026-11-17。新增抖音解析有限重试与分类诊断，其他平台沿用 0.3.5 流程。此前 YouTube 由本人确认恢复，未找到可复现的失败链接。

底部展示常用平台标识；「更多网站」可离线搜索当前 yt-dlp 2026.10.26 的 1755 项解析器。解析器数量不等于网站数量，列在名单中也不保证每条视频始终可用。其他网站直接粘贴到原下载框即可尝试。

|来源|接入方式与验证范围|
|---|---|
|YouTube|独立登录、JavaScript 运行时；本次用户确认可用|
|Instagram|新增独立识别、登录/导入 Cookie、媒体库分类与失效后一次登录重试；官方公开 Reel 实际下载与完整解码通过，账号受限内容未实测|
|哔哩哔哩、X、TikTok|沿用已有平台识别与独立登录，本次未逐一重新下载|
|抖音|视频与图文；解析最多尝试 3 次，输出具体诊断；明确验证、下架或登录门槛时停止重试|
|小红书|沿用视频与图文流程，需要时登录|
|微信|公众号图文；视频号用专栏动态抓取与确认封面，已有真实下载证据|
|光厂片场|沿用案例详情公开播放版；底部用名称展示|
|Vimeo|新增独立分类，使用 yt-dlp 解析；本次未用真实链接验证|
|Facebook、Reddit、Twitch 等|已包含在上游解析名单，通过通用入口尝试；本次未逐站验证|
|MP4 直链、M3U8|通用入口，本机 HTTP 服务上的真实下载与完整解码通过；MP4 下载前后 SHA-256 一致|

登录、私密、地区、直播和 DRM 内容可能需要不同条件；本版不承诺下载所有网站或所有内容。Instagram 登录成功后的私密内容、Stories、合集尚未逐项验收。

依据：[yt-dlp 支持名单](https://github.com/yt-dlp/yt-dlp/blob/2026.10.26/supportedsites.md)、[Instagram 官方适配器与测试样本](https://github.com/yt-dlp/yt-dlp/blob/2026.10.26/yt_dlp/extractor/instagram.py)、[下载引擎版本](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26)。图标来自 [Simple Icons](https://github.com/simple-icons/simple-icons)，CC0 许可随包保留。

## 本次验收

- 22 项 WPF 检查通过，包含网站搜索、860×620 最小窗口排版，以及原微信栏目回归；截图在 `.build/platforms035-ui`。
- 3 项 Instagram 账号范围、伪装域名和登录失败后临时 Cookie 清理测试通过。
- 新构建 worker + 新引擎下载 MP4、M3U8、Instagram Reel，三份成品完整解码通过；结果在 `.build/platforms035/result.json`。Instagram 样本 1,949,801 字节、4.966667 秒。
- 引擎 SHA-256：`f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d`。
- 0.3.6 新增 16 项抖音解析检查（含真实浏览器验证可见/隐藏验证元素），队列确认普通解析失败不会打开登录窗口；更新器检查通过。便携包实网验证见 [STATUS.md](STATUS.md)。
- 正式包、旧版更新器与升级验证见 [0.3.6 发行记录](releases/v0.3.6-validation.md)。

## 经验候选（待本人确认）

行动：用公开 Reel 贯穿新 worker、平台路由和下载引擎；结果：下载、时长和完整解码一致通过。原因：站点识别与成品可用是不同验收点。验收：文件字节数、ffprobe 和完整解码。反例：仅在支持名单中搜到 Instagram 就宣称下载通过。边界：单条公开 Reel 不代表私密内容、Stories 或所有网站均通过。
