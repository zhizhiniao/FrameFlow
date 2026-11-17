"""Portable login/download worker. Never prints cookie values or account responses."""
import argparse
import ctypes
import http.cookiejar
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

if sys.stdout:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
    sys.stderr.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)

ROOT = Path(sys.executable).resolve().parent.parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
if not getattr(sys, "frozen", False):
    current = json.loads((ROOT / 'app-version.json').read_text(encoding='utf-8-sig'))['version']
    for version in dict.fromkeys((current, "0.3.4", "0.2.4", "0.2.3", "0.2.2", "0.2.1", "0.2.0")):
        bundle = ROOT / "release" / ("FrameFlow-Portable-v" + version)
        if (bundle / "worker/FrameFlow.Worker.exe").exists():
            ROOT = bundle
            break

PLATFORMS = {
    "bilibili": ("哔哩哔哩", "https://www.bilibili.com/", ("bilibili.com",)),
    "youtube": ("YouTube", "https://www.youtube.com/", ("youtube.com", "google.com")),
    "instagram": ("Instagram", "https://www.instagram.com/", ("instagram.com",)),
    "tiktok": ("TikTok", "https://www.tiktok.com/", ("tiktok.com",)),
    "twitter": ("X (Twitter)", "https://x.com/i/flow/login", ("x.com", "twitter.com")),
    "xhs": ("小红书", "https://www.xiaohongshu.com/explore", ("xiaohongshu.com",)),
    "douyin": ("抖音", "https://www.douyin.com/", ("douyin.com",)),
}

class LoginRequired(RuntimeError):
    pass


class CookieRefreshRequired(RuntimeError):
    pass


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.new")
    tmp.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def safe_log(line):
    # Share URLs can contain access/signature tokens; keep them out of persistent logs.
    return re.sub(r'(https?://[^\s?]+)\?[^\s]+', r'\1?[query hidden]', line)


def dpapi(data, decrypt=False):
    class Blob(ctypes.Structure):
        _fields_ = [("size", ctypes.c_ulong), ("data", ctypes.POINTER(ctypes.c_ubyte))]
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    dest = Blob()
    function = ctypes.windll.crypt32.CryptUnprotectData if decrypt else ctypes.windll.crypt32.CryptProtectData
    # CRYPTPROTECT_UI_FORBIDDEN; CurrentUser scope, not machine scope.
    if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(dest)):
        raise RuntimeError("无法读取本机登录态，请重新登录。")
    try:
        return ctypes.string_at(dest.data, dest.size)
    finally:
        ctypes.windll.kernel32.LocalFree(dest.data)


def filtered_cookies(cookies, platform):
    domains = PLATFORMS[platform][2]
    return [c for c in cookies if any(c["domain"].lstrip(".") == d or c["domain"].lstrip(".").endswith("." + d) for d in domains)
            and (c.get("expires", -1) <= 0 or c["expires"] > time.time())]


def has_auth(cookies, platform, account_confirmed=False):
    names = {c["name"] for c in filtered_cookies(cookies, platform) if c.get("value")}
    if platform == 'bilibili':
        return 'SESSDATA' in names
    if platform in ("douyin", "tiktok"):
        return bool(names & {"sessionid", "sessionid_ss", "sid_guard"})
    if platform == "instagram":
        return "sessionid" in names
    if platform == "twitter":
        # Guest cookies (including ct0 alone) do not establish an account session.
        for domain in PLATFORMS[platform][2]:
            scoped = {c["name"] for c in filtered_cookies(cookies, platform) if c.get("value")
                      and (c["domain"].lstrip(".") == domain or c["domain"].lstrip(".").endswith("." + domain))}
            if {"auth_token", "ct0"} <= scoped:
                return True
        return False
    if platform == "youtube":
        names = {c["name"] for c in filtered_cookies(cookies, platform) if c.get("value") and (c["domain"].lstrip(".") == "youtube.com" or c["domain"].lstrip(".").endswith(".youtube.com"))}
        return bool(names & {"SID", "__Secure-1PSID", "__Secure-3PSID"}) and bool(names & {"SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"})
    # web_session also exists for anonymous XHS visitors. Require an account response.
    return "web_session" in names and account_confirmed


def save_session(data, platform, cookies, source="browser"):
    cookies = filtered_cookies(cookies, platform)
    folder = Path(data) / "sessions"
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / (platform + ".bin")
    tmp = dest.with_suffix(f".{os.getpid()}.new")
    tmp.write_bytes(dpapi(json.dumps(cookies).encode("utf-8")))
    os.replace(tmp, dest)
    atomic_json(folder / (platform + ".json"), {"saved_at": time.strftime("%Y-%m-%d %H:%M"), "source": source, "download_verified": False})


def load_session(data, platform):
    dest = Path(data) / "sessions" / (platform + ".bin")
    if not dest.exists():
        return []
    return filtered_cookies(json.loads(dpapi(dest.read_bytes(), True)), platform)


def cloud_config(data, platform):
    if platform == 'youtube':
        settings = auth_settings(data)
        if settings['source'] != 'cloud':
            return None
        if settings.get('endpoint'):
            return dict(settings, platforms=['youtube'])
    path = Path(data) / 'cookiecloud.bin'
    if not path.exists():
        return None
    try:
        config = json.loads(dpapi(path.read_bytes(), True))
        return config if platform in config.get('platforms', []) else None
    except Exception:
        raise RuntimeError('CookieCloud 本机连接配置不可读取，请重新连接。') from None


def auth_settings(data):
    path = Path(data) / 'auth-settings.bin'
    defaults = dict(source='browser', proxy='', auto_refresh=True)
    if path.exists():
        try:
            defaults.update(json.loads(dpapi(path.read_bytes(), True)))
        except Exception:
            raise RuntimeError('登录设置无法读取，请在 Cookie 设置中重新保存。') from None
    return defaults


def session_profile(data, platform):
    # Keep the previously blocked Chromium profile intact; use an isolated new profile.
    return Path(data) / 'profiles' / ('youtube-browser-v2' if platform == 'youtube' else platform)


def youtube_browser_path():
    candidates = [
        Path(os.environ.get('LOCALAPPDATA', '')) / 'Google/Chrome/Application/chrome.exe',
        Path(os.environ.get('PROGRAMFILES', 'C:/Program Files')) / 'Google/Chrome/Application/chrome.exe',
        Path(os.environ.get('PROGRAMFILES(X86)', 'C:/Program Files (x86)')) / 'Microsoft/Edge/Application/msedge.exe',
        Path(os.environ.get('PROGRAMFILES', 'C:/Program Files')) / 'Microsoft/Edge/Application/msedge.exe',
    ]
    for path in candidates:
        if path.is_file():
            return str(path)
    return browser_path()


def browser_driver(platform):
    if platform == 'youtube':
        from patchright.sync_api import sync_playwright
    else:
        from playwright.sync_api import sync_playwright
    return sync_playwright()


def login_blocked(page):
    if urllib.parse.urlsplit(page.url).hostname != 'accounts.google.com':
        return False
    try:
        text = page.locator('body').inner_text(timeout=2000)
        return bool(re.search(r'此浏览器或应用可能不安全|This browser or app may not be secure', text, re.I))
    except Exception:
        return False


def refresh_browser(data):
    """Serialize profile access across concurrent downloads; retain credentials on failure."""
    import msvcrt
    profile = session_profile(data, 'youtube')
    if not (profile / 'Default').exists():
        return
    lock_path = Path(data) / 'youtube-refresh.lock'
    with lock_path.open('a+b') as lock:
        lock.seek(0)
        if not lock.read(1): lock.write(b'0'); lock.flush()
        lock.seek(0)
        try: msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError: return
        try:
            meta = Path(data) / 'sessions/youtube.json'
            if meta.exists() and time.time() - meta.stat().st_mtime < 300: return
            cfg = auth_settings(data)
            options = {'proxy': {'server': cfg['proxy']}} if cfg.get('proxy') else {}
            with browser_driver('youtube') as p:
                ctx = p.chromium.launch_persistent_context(str(profile), executable_path=youtube_browser_path(),
                    headless=True, timeout=20000, **options)
                try:
                    page = ctx.pages[0] if ctx.pages else ctx.new_page()
                    page.goto(PLATFORMS['youtube'][1], wait_until='domcontentloaded', timeout=25000)
                    page.wait_for_timeout(2000)
                    cookies = ctx.cookies()
                    if has_auth(cookies, 'youtube'): save_session(data, 'youtube', cookies)
                finally: ctx.close()
        except Exception:
            print('[登录] 自动刷新未完成，保留原会话；可在 Cookie 设置中重新登录。')
        finally:
            lock.seek(0); msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def sync_cloud(data, platform, config=None):
    from cookiecloud_client import fetch_cookies
    config = config or cloud_config(data, platform)
    if not config:
        raise RuntimeError('尚未连接此平台的 CookieCloud。')
    cookies, updated = fetch_cookies(config, PLATFORMS[platform][2])
    if not has_auth(cookies, platform):
        raise CookieRefreshRequired('CookieCloud 中没有有效的账号 Cookie。请在日常浏览器登录 YouTube，并在扩展中同步后重试。')
    save_session(data, platform, cookies, 'cookiecloud')
    meta = Path(data) / 'sessions' / (platform + '.json')
    value = json.loads(meta.read_text(encoding='utf-8'))
    value['cloud_updated_at'] = updated
    atomic_json(meta, value)
    print('[登录] 已从 CookieCloud 同步最新的平台登录态。')
    return cookies


def download_cookies(data, platform):
    if platform == 'youtube':
        cfg = auth_settings(data)
        if cfg['source'] == 'browser' and cfg.get('auto_refresh', True):
            refresh_browser(data)
    config = cloud_config(data, platform)
    if config:
        try:
            return sync_cloud(data, platform, config)
        except CookieRefreshRequired:
            raise
        except RuntimeError:
            cached = load_session(data, platform)
            if not has_auth(cached, platform): raise
            print('[登录] CookieCloud 暂时不可用，本次使用上次保存的登录态。')
            return cached
    return load_session(data, platform)


def netscape(cookies):
    lines = ["# Netscape HTTP Cookie File"]
    for c in cookies:
        # Netscape is tab-separated; reject malformed fields instead of injecting lines.
        if any(any(ch in str(c.get(k, "")) for ch in "\t\r\n") for k in ("domain", "path", "name", "value")):
            continue
        domain = ("#HttpOnly_" if c.get("httpOnly") else "") + c["domain"]
        lines.append("\t".join((domain, "TRUE" if c["domain"].startswith(".") else "FALSE", c.get("path", "/"),
                                "TRUE" if c.get("secure") else "FALSE", str(max(0, int(c.get("expires", 0)))), c["name"], c["value"])))
    return "\n".join(lines) + "\n"


def browser_path(playwright=None):
    bundled = ROOT / "browser" / "chrome.exe"
    if bundled.exists():
        return str(bundled)
    if getattr(sys, "frozen", False):
        raise RuntimeError("登录浏览器缺失，请完整解压便携包后重试。")
    if playwright is not None:
        return playwright.chromium.executable_path
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        return p.chromium.executable_path


def node_path():
    bundled = ROOT / "worker" / "_internal" / "playwright" / "driver" / "node.exe"
    if bundled.exists():
        return str(bundled)
    if getattr(sys, "frozen", False):
        raise RuntimeError("JavaScript 组件缺失，请重新解压便携包。")
    import playwright
    return str(Path(playwright.__file__).parent / "driver" / "node.exe")


def login(args):
    if cloud_config(args.data, args.platform):
        sync_cloud(args.data, args.platform)
        atomic_json(args.result, {'status': 'saved', 'message': '已从 CookieCloud 更新登录态，无需重复登录。', 'platform': args.platform})
        return 0
    platform = args.platform
    profile = session_profile(args.data, platform)
    profile.mkdir(parents=True, exist_ok=True)
    state = {"account": False}
    def event(status, message):
        atomic_json(args.result, {"status": status, "message": message, "platform": platform})
    def observe(response):
        # Inspect only the managed browser's own account-status response; never persist it.
        try:
            host = urllib.parse.urlsplit(response.url).hostname or ""
            route = urllib.parse.urlsplit(response.url).path.rstrip("/")
            if platform == "xhs" and (host == "xiaohongshu.com" or host.endswith(".xiaohongshu.com")) and route.endswith(("/user/me", "/user/selfinfo")):
                body = response.json()
                info = body.get("data", {})
                if isinstance(info, dict) and body.get("code") == 0 and (info.get("guest") is False or info.get("is_guest") is False):
                    state["account"] = True
        except Exception:
            pass
    event("waiting", "请在打开的窗口完成登录；识别成功后窗口会自动关闭。")
    cfg = auth_settings(args.data) if platform == 'youtube' else {}
    options = {'proxy': {'server': cfg['proxy']}} if cfg.get('proxy') else {}
    with browser_driver(platform) as p:
        # Dedicated persistent profile. No access to the user's daily browser profile.
        executable = youtube_browser_path() if platform == 'youtube' else browser_path(p)
        ctx = p.chromium.launch_persistent_context(str(profile), executable_path=executable, headless=False,
                chromium_sandbox=True, locale="zh-CN", viewport=None, accept_downloads=False,
                args=["--disable-save-password-bubble", "--lang=zh-CN"],
                ignore_default_args=["--enable-automation"], **options)
        try:
            ctx.on("response", observe)
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            try:
                page.goto('https://www.youtube.com/signin' if platform == 'youtube' else PLATFORMS[platform][1], wait_until="domcontentloaded", timeout=60000)
            except Exception:
                event("waiting", "页面加载较慢，可在登录窗口刷新；关闭窗口可取消。")
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                if Path(args.cancel).exists():
                    event("cancelled", "登录已取消。")
                    return 2
                pages = [v for v in ctx.pages if not v.is_closed()]
                if not pages:
                    event("cancelled", "登录窗口已关闭，尚未保存新的登录态。")
                    return 2
                if platform == 'youtube' and any(login_blocked(page) for page in pages):
                    event('blocked', 'Google 拒绝了当前登录浏览器。请在日常 Chrome 中登录，再通过 Cookie 设置选择外部 CookieCloud 或导入 Cookie 文件；原会话已保留。')
                    return 2
                cookies = ctx.cookies()
                if has_auth(cookies, platform, state["account"]):
                    # Allow redirects to settle so all platform-scoped session cookies arrive.
                    pages[0].wait_for_timeout(1800)
                    cookies = ctx.cookies()
                    if has_auth(cookies, platform, state["account"]):
                        save_session(args.data, platform, cookies)
                        event("saved", "登录态已自动保存；首次下载将验证其是否可用。")
                        return 0
                pages[0].wait_for_timeout(500)
            event("timeout", "等待登录超时，请重试。平台验证码或扫码需要本人完成。")
            return 2
        except Exception:
            event("cancelled", "登录窗口已关闭或连接中断，请重试。")
            return 2
        finally:
            ctx.close()


def import_session(args):
    jar = http.cookiejar.MozillaCookieJar(args.file)
    jar.load(ignore_discard=True, ignore_expires=False)
    cookies = [{"name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "secure": c.secure,
                "expires": c.expires or -1, "httpOnly": c.has_nonstandard_attr("HTTPOnly"), "sameSite": "Lax"} for c in jar]
    cookies = filtered_cookies(cookies, args.platform)
    if not cookies:
        raise RuntimeError("文件中没有该平台的有效 Cookie。")
    save_session(args.data, args.platform, cookies, "import")
    print("[登录] 已导入该平台 Cookie，是否可用将在下载时验证。")
    return 0


def wx_article(url, output):
    def fetch(link):
        return urllib.request.urlopen(urllib.request.Request(link, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://mp.weixin.qq.com/"}), timeout=40).read()
    html = fetch(url).decode("utf-8")
    title = re.search(r'property="og:title"[^>]*content="([^"]+)"', html)
    title = title[1] if title else "微信文章_" + time.strftime("%Y%m%d%H%M%S")
    images = list(dict.fromkeys(re.findall(r'https://mmbiz\.qpic\.cn/[A-Za-z0-9_/-]+/[0-9]+\?wx_fmt=[a-zA-Z]+', html)))
    if not images:
        raise RuntimeError("未找到文章图片；文章可能失效或需要在浏览器验证。")
    folder = Path(output) / re.sub(r'[\\/:*?"<>|]', "_", title)[:60]
    folder.mkdir(parents=True, exist_ok=True)
    for n, image in enumerate(images, 1):
        ext = image.rsplit("=", 1)[-1]
        (folder / (f"{n:02d}." + (ext if ext in ("jpg", "jpeg", "png", "webp", "gif") else "jpg"))).write_bytes(fetch(image))
    (folder / "文章信息.txt").write_text(f"标题：{title}\n来源：{url}\n图片：{len(images)}\n", encoding="utf-8")
    print(f"[图文] 已保存 {len(images)} 张图片，可点击打开目录查看。")
    return 0


def resolve_platform(platform, url):
    host = (urllib.parse.urlsplit(url).hostname or '').lower()
    if platform == 'auto' and (host == 'b23.tv' or host == 'bilibili.com' or host.endswith('.bilibili.com')):
        return 'bilibili'
    if platform == 'auto' and (host == 'instagram.com' or host.endswith('.instagram.com')):
        return 'instagram'
    return platform


def download(args):
    args.platform = resolve_platform(args.platform, args.url)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    if args.platform == "weixin":
        return wx_article(args.url, output)
    try:
        cookies = download_cookies(args.data, args.platform) if args.platform in PLATFORMS else []
    except CookieRefreshRequired:
        raise
    except RuntimeError:
        if (Path(args.data) / 'cookiecloud.bin').exists():
            raise
        raise LoginRequired("本机登录态不可读取，请重新登录。")
    if args.platform in ("douyin", "xhs") and not cookies:
        raise LoginRequired("请先点击「平台登录」完成登录，再开始下载。")
    url = args.url
    if args.platform in ("douyin", "xhs"):
        import browser_media
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            refreshed=browser_media.run(args,p,browser_path(p),args.data,output,ROOT,cookies)
            save_session(args.data,args.platform,refreshed)
            meta=Path(args.data)/'sessions'/(args.platform+'.json')
            value=json.loads(meta.read_text(encoding='utf-8'));value['download_verified']=True
            atomic_json(meta,value)
            return 0
    tempdir = Path(args.data) / "temp"
    tempdir.mkdir(parents=True, exist_ok=True)
    cookie_file = None
    try:
        command = [str(ROOT / "yt-dlp.exe"), "--ignore-config", "--no-playlist", "--newline", "--encoding", "utf-8",
                   "--js-runtimes", "node:" + node_path(), "--ffmpeg-location", str(ROOT / "ffmpeg" / "bin"),
                   "--windows-filenames", "--trim-filenames", "170", "-o", str(output / "%(title)s-[%(id)s].%(ext)s")]
        if args.platform == 'youtube' and auth_settings(args.data).get('proxy'):
            command += ['--proxy', auth_settings(args.data)['proxy']]
        if args.platform == 'bilibili':
            command += ['--http-chunk-size', '1M', '--socket-timeout', '30', '--retries', '3',
                        '--fragment-retries', '3', '--merge-output-format', 'mp4']
        if cookies:
            descriptor, cookie_file = tempfile.mkstemp(prefix="session-", suffix=".txt", dir=tempdir)
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(netscape(cookies))
            command += ["--cookies", cookie_file]
        if args.platform in PLATFORMS:
            command += ["--referer", "https://x.com/" if args.platform == "twitter" else PLATFORMS[args.platform][1]]
        if args.platform == "twitter":
            # Use Windows trust roots, including locally trusted network certificates.
            # Certificate validation remains enabled; never use --no-check-certificates.
            command += ["--compat-options", "no-certifi"]
        command += ["--", url]
        auth_error = False
        bili_blocked = False
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", errors="replace", creationflags=subprocess.CREATE_NO_WINDOW) as proc:
            for line in proc.stdout:
                print(safe_log(line), end="")
                if args.platform == 'bilibili' and re.search(r'HTTP Error (?:412|403)|blocked by server|风控', line, re.I):
                    bili_blocked = True
                if re.search(r"fresh cookies|cookies are no longer valid|sign in to confirm|login required|log in to access|you need to log in|login_required|use --cookies|could not authenticate you|invalid or expired token|需要登录", line, re.I):
                    auth_error = True
            code = proc.wait()
        if code and bili_blocked:
            if not has_auth(cookies, 'bilibili'):
                print('[提示] B 站拒绝了未登录请求（412/403）。将引导一次 B 站登录，完成后继续原任务。')
                return 10
            print('[提示] B 站仍拒绝当前请求（412/403）。请在「平台登录 → 哔哩哔哩」更新登录态，并检查原视频是否可播放、网络是否正常，然后重试失败任务。不会自动反复登录。')
            return 12
        if code == 0 and cookies:
            meta = Path(args.data) / "sessions" / (args.platform + ".json")
            value = json.loads(meta.read_text(encoding="utf-8"))
            value["download_verified"] = True
            atomic_json(meta, value)
        elif code:
            if auth_error and args.platform == 'youtube' and cookies:
                print('[提示] YouTube 拒绝了当前会话。请打开「Cookie 设置」登录 / 更新，再点击「重试失败任务」。')
                return 11
            print("[提示] 若提示登录失效，请在「平台登录」中重新登录；网络错误请检查网络后重试。")
        return 10 if code and auth_error and args.platform in PLATFORMS else code
    finally:
        if cookie_file:
            Path(cookie_file).unlink(missing_ok=True)


def doctor(args):
    components = {"yt-dlp": ROOT / "yt-dlp.exe", "ffmpeg": ROOT / "ffmpeg/bin/ffmpeg.exe", "ffprobe": ROOT / "ffmpeg/bin/ffprobe.exe",
                  "node": Path(node_path()), "browser": Path(browser_path())}
    result = {k: v.is_file() for k, v in components.items()}
    if args.browser_test:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=browser_path(p), headless=True, chromium_sandbox=True)
            try:
                page = browser.new_page()
                page.set_content("<title>FrameFlow component check</title>")
                result["browser_launch"] = page.title() == "FrameFlow component check"
            finally:
                browser.close()
        with browser_driver('youtube') as p:
            browser = p.chromium.launch(executable_path=youtube_browser_path(), headless=True)
            try:
                page = browser.new_page()
                page.set_content('<title>YouTube login runtime check</title>')
                result['youtube_browser_launch'] = page.title() == 'YouTube login runtime check'
            finally:
                browser.close()
    result["node_launch"] = subprocess.run([node_path(), "--version"], capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW).returncode == 0
    print(json.dumps(result))
    return 0 if all(result.values()) else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["login", "download", "import", "forget", "doctor"])
    parser.add_argument("--data", required=True)
    parser.add_argument("--platform", choices=list(PLATFORMS) + ["auto", "weixin"], default="auto")
    parser.add_argument("--url")
    parser.add_argument("--output")
    parser.add_argument("--result")
    parser.add_argument("--cancel", default="")
    parser.add_argument("--file")
    parser.add_argument("--browser-test", action="store_true")
    args = parser.parse_args()
    try:
        if args.action == "forget":
            if args.platform not in PLATFORMS:
                raise RuntimeError("请选择一个平台。")
            config = cloud_config(args.data, args.platform)
            if config:
                config['platforms'].remove(args.platform)
                if config['platforms']:
                    (Path(args.data) / 'cookiecloud.bin').write_bytes(dpapi(json.dumps(config).encode()))
                    atomic_json(Path(args.data) / 'cookiecloud.json', {'platforms': config['platforms'], 'provider': 'CookieCloud'})
                else:
                    (Path(args.data) / 'cookiecloud.bin').unlink(missing_ok=True)
                    (Path(args.data) / 'cookiecloud.json').unlink(missing_ok=True)
            for suffix in (".bin", ".json"):
                (Path(args.data) / "sessions" / (args.platform + suffix)).unlink(missing_ok=True)
            folder = session_profile(Path(args.data).resolve(), args.platform)
            if folder.exists():
                shutil.rmtree(folder)
            if args.platform == 'youtube':
                legacy = Path(args.data).resolve() / 'profiles/youtube'
                if legacy.exists(): shutil.rmtree(legacy)
            print("[登录] 已清除所选平台的本机登录态。")
            return 0
        return {"login": login, "download": download, "import": import_session, "doctor": doctor}[args.action](args)
    except Exception as exc:
        # Browser exceptions may include response URLs. Do not dump tracebacks/account data.
        message = str(exc) if isinstance(exc, RuntimeError) else "操作未完成，请检查网络、完整解压组件后重试。"
        print("[错误] " + message)
        if args.action == "login" and args.result:
            atomic_json(args.result, {"status": "error", "message": message, "platform": args.platform})
        return 11 if isinstance(exc, CookieRefreshRequired) else 10 if isinstance(exc, LoginRequired) else 1


if __name__ == "__main__":
    sys.exit(main())
