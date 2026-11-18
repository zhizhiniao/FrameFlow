"""Download media exposed by the user's authenticated, normal platform page."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

from playwright.sync_api import Error as BrowserError


def _network_reason(error):
    # Playwright messages contain full URLs and request headers. Keep only a code.
    match = re.search(r'net::(ERR_[A-Z0-9_]+)', str(error))
    if match:
        return match[1]
    message = str(error).lower()
    if 'timeout' in type(error).__name__.lower() or 'timeout' in message:
        return '等待超时'
    if 'execution context was destroyed' in message or 'cannot find context with specified id' in message:
        return '页面跳转导致执行上下文重建'
    if 'interrupted by another navigation' in message:
        return '当前导航被另一次页面跳转打断'
    if 'has been closed' in message:
        return '页面或浏览器已关闭'
    return '浏览器操作失败'


def _douyin_gate(page):
    return page.evaluate('''() => {
        const visible = e => {
            if (!e) return false;
            const r = e.getBoundingClientRect(), s = getComputedStyle(e);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' &&
                s.display !== 'none' && s.opacity !== '0';
        };
        if ([...document.querySelectorAll('#captcha_container,.captcha_verify_container')].some(visible))
            return 'verification';
        const messages = [...document.querySelectorAll('p,span,div,h1,h2')]
            .filter(e => e.children.length === 0 && visible(e)).map(e => e.innerText?.trim());
        if (messages.some(t => /^(请完成安全验证|请完成下方验证|拖动滑块完成验证)$/.test(t))) return 'verification';
        if (messages.some(t => /^(该作品已被删除|作品已删除|视频已删除|作品不存在|作品已下架)[。！!]?$/.test(t)))
            return 'unavailable';
        if (location.pathname === '/login' || messages.some(t =>
            /^(登录已过期|登录失效，请重新登录|请登录后观看|登录后才能观看)[。！!]?$/.test(t))) return 'login';
        return null;
    }''')


def parse_douyin(page, context, url, attempts=3, wait_seconds=20):
    """Retry only page parsing, before any media is written; preserve the session."""
    details, state = {}, {}
    detail_path = '/aweme/v1/web/aweme/detail/'

    def observe(response):
        parsed = urllib.parse.urlsplit(response.url)
        if parsed.hostname != 'www.douyin.com' or parsed.path != detail_path:
            return
        status = response.status
        parts = [f'详情接口 HTTP {status}']
        state['detail'] = '，'.join(parts)
        if status < 200 or status >= 300:
            state['retry_http'] = True
            if status == 429:
                state['delay'] = 30
            return
        try:
            payload = response.json()
        except (ValueError, BrowserError, TypeError):
            kind = response.headers.get('content-type', '').split(';')[0].lower()
            kind = kind if kind in ('text/html', 'text/plain', 'application/json') else '未知类型'
            state['detail'] = '，'.join(parts + [f'非有效 JSON（{kind}）'])
            return
        if not isinstance(payload, dict):
            state['detail'] = '，'.join(parts + ['JSON 结构异常'])
            return
        code = str(payload.get('status_code', ''))
        if re.fullmatch(r'-?\d{1,12}', code):
            parts.append('业务码 ' + code)
        item = payload.get('aweme_detail')
        if not isinstance(item, dict) or not re.fullmatch(r'\d+', str(item.get('aweme_id', ''))):
            parts.append('缺少 aweme_detail 或作品 ID')
        else:
            details[str(item['aweme_id'])] = item
            parts.append('已返回作品数据')
        state['detail'] = '，'.join(parts)

    def failed(request):
        parsed = urllib.parse.urlsplit(request.url)
        if parsed.hostname == 'www.douyin.com' and parsed.path == detail_path:
            state['detail'] = '详情接口请求失败（' + _network_reason(request.failure or '') + '）'

    context.on('response', observe)
    context.on('requestfailed', failed)
    current_url, ident = url, ''
    terminal = {
        'verification': '抖音页面要求安全验证，请在平台页面完成验证后重试。',
        'unavailable': '抖音作品已删除、下架或不可访问，请检查作品链接。',
        'login': '抖音页面明确要求登录后观看，请在平台登录中更新登录态。',
    }
    try:
        for attempt in range(1, attempts + 1):
            details.clear()
            state.clear()
            reason, gate = '', None
            stage = '打开作品页面'
            try:
                response = page.goto(current_url, wait_until='domcontentloaded', timeout=30000)
                if response is not None:
                    state['page'] = f'页面 HTTP {response.status}'
                    if response.status in (404, 410):
                        gate = 'unavailable'
                    elif response.status >= 400:
                        reason = state['page']
                        stage = '读取错误页面状态'
                        gate = _douyin_gate(page)
                if not reason and not gate:
                    stage = '等待分享链接跳转'
                    page.wait_for_url(re.compile(r'https://(?:www\.)?douyin\.com/(video|note)/\d+'), timeout=10000)
                    match = re.search(r'/(?:video|note)/(\d+)', page.url)
                    if not match:
                        reason = '分享链接未跳转到作品页面'
                    else:
                        ident = match[1]
                        current_url = 'https://www.douyin.com/' + match[0].lstrip('/')
                        deadline = time.monotonic() + wait_seconds
                        stage = '读取作品数据与页面状态'
                        while True:
                            item = details.get(ident)
                            if item:
                                if item.get('images') or media_candidates(item.get('video') or {}, 'douyin'):
                                    print(f'[解析] 第 {attempt}/{attempts} 次解析成功（作品 ID {ident}）。', flush=True)
                                    return ident, item
                                reason = '作品数据缺少可用媒体地址'
                                break
                            gate = _douyin_gate(page)
                            if gate or state.get('retry_http') or time.monotonic() >= deadline:
                                break
                            page.wait_for_timeout(400)
                        if not gate and not reason:
                            reason = state.get('detail', f'等待 {wait_seconds} 秒，详情接口未响应')
                            if details:
                                reason += '，返回的作品 ID 与目标不匹配'
            except BrowserError as exc:
                reason = stage + '：' + _network_reason(exc)
                # Redirects to a login/verification page may also time out wait_for_url.
                try:
                    gate = _douyin_gate(page)
                except BrowserError:
                    pass
            if gate:
                reason = terminal.get(gate, '作品页面暂不可访问')
            summary = '；'.join(dict.fromkeys(x for x in (state.get('page'), state.get('detail'), reason) if x))
            print(f'[诊断] 抖音解析 {attempt}/{attempts}，作品 ID {ident or "未知"}：{summary}', flush=True)
            if gate:
                raise RuntimeError(reason)
            if attempt == attempts:
                raise RuntimeError(f'抖音解析已尝试 {attempts} 次仍失败：{reason}。请稍后重试，具体原因见上方诊断日志。')
            delay = state.get('delay', 2 ** attempt)
            print(f'[重试] {delay} 秒后自动重新解析（第 {attempt + 1}/{attempts} 次），沿用当前登录态。', flush=True)
            page.wait_for_timeout(delay * 1000)
    finally:
        context.remove_listener('response', observe)
        context.remove_listener('requestfailed', failed)


def media_candidates(video, platform):
    result=[]
    if platform=='douyin':
        variants=sorted(video.get('bit_rate') or [],key=lambda x:x.get('bit_rate',0),reverse=True)
        for item in variants+[video]:
            address=item.get('play_addr') or {}
            result.extend(address.get('url_list') or [])
    else:
        streams=video.get('media',{}).get('stream',{})
        for codec in ('h264','h265','av1'):
            for stream in sorted(streams.get(codec) or [],key=lambda x:x.get('videoBitrate',0),reverse=True):
                result.extend([stream.get('masterUrl')]+(stream.get('backupUrls') or []))
        if video.get('url'):result.append(video['url'])
    return list(dict.fromkeys(u for u in result if isinstance(u,str) and u.startswith(('https://','http://'))))


def retrieve(url, destination, ua, referer):
    partial=Path(str(destination)+'.part')
    try:
        req=urllib.request.Request(url,headers={'User-Agent':ua,'Referer':referer})
        with urllib.request.urlopen(req,timeout=60) as response,partial.open('wb') as output:
            if 'text/html' in response.headers.get('Content-Type',''):
                raise RuntimeError('下载地址返回了网页，请重新打开作品链接。')
            total=int(response.headers.get('Content-Length',0));received=0;last=-1
            while True:
                chunk=response.read(1024*512)
                if not chunk:break
                output.write(chunk);received+=len(chunk)
                percent=int(received*100/total) if total else 0
                if percent>=last+5:
                    print(f'[download] {min(percent,99)}%  已接收 {received/1048576:.1f} MB',flush=True);last=percent
        if not received or (total and total!=received):raise RuntimeError('媒体传输未完成，请重试。')
        os.replace(partial,destination)
    finally:
        partial.unlink(missing_ok=True)


def run(args, playwright, browser_exe, data, output, root, cookies):
    platform=args.platform
    context=playwright.chromium.launch_persistent_context(str(Path(data)/'profiles'/platform),executable_path=browser_exe,
            headless=True,chromium_sandbox=True,locale='zh-CN',ignore_default_args=['--enable-automation'])
    # Keep fresher browser state. Re-inject only imports or a newly-created profile.
    meta_path=Path(data)/'sessions'/(platform+'.json')
    meta=json.loads(meta_path.read_text(encoding='utf-8')) if meta_path.exists() else {}
    if meta.get('source')=='import' or not context.cookies():
        context.add_cookies(cookies)
    try:
        page=context.pages[0] if context.pages else context.new_page()
        print('[解析] 正在使用本机登录态打开作品页面…',flush=True)
        if platform=='douyin':
            ident,item=parse_douyin(page,context,args.url)
            title=item.get('desc') or ident
            images=item.get('images') or []
            video=item.get('video') or {}
        else:
            page.goto(args.url,wait_until='domcontentloaded',timeout=60000)
            deadline=time.monotonic()+20;item=None;ident=''
            while time.monotonic()<deadline:
                if '/404' in page.url:raise RuntimeError('小红书链接已失效或缺少分享参数，请重新复制完整分享链接。')
                found=re.search(r'/(?:explore|discovery/item)/([a-f0-9]+)',page.url)
                if found:
                    ident=found[1]
                    item=page.evaluate('''id => {const m=window.__INITIAL_STATE__?.note?.noteDetailMap; const n=m?.[id]?.note; return n&&Object.keys(n).length?{title:n.title,desc:n.desc,type:n.type,video:n.video,imageList:n.imageList}:null}''',ident)
                # The initial note shell precedes the hydrated media URLs.
                if item and (media_candidates(item.get('video') or {},platform) if item.get('type')=='video' else item.get('imageList')):break
                page.wait_for_timeout(400)
            if not item:raise RuntimeError('作品暂不可访问。请使用完整小红书分享链接，并确认该账号可在网页中查看。')
            title=item.get('title') or item.get('desc') or ident
            images=[] if item.get('type')=='video' else item.get('imageList') or []
            video=item.get('video') or {}
        ua=page.evaluate('navigator.userAgent')
        referer='https://www.douyin.com/' if platform=='douyin' else 'https://www.xiaohongshu.com/'
        safe=re.sub(r'[\\/:*?"<>|\x00-\x1f]','_',title).strip(' .')[:90] or ident
        safe=re.sub(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',r'_\1',safe,flags=re.I)
        if images:
            folder=Path(output)/(safe+'-['+ident+']');folder.mkdir(exist_ok=True)
            for index,img in enumerate(images,1):
                live=img.get('video') or {}
                live_urls=(live.get('play_addr') or live.get('download_addr') or {}).get('url_list') or []
                if live_urls:
                    retrieve(live_urls[0],folder/f'{index:02d}.mp4',ua,referer)
                    continue
                urls=(img.get('url_list') or []) if platform=='douyin' else [x.get('url') for x in img.get('infoList',[])]+[img.get('urlDefault'),img.get('urlPre')]
                urls=[u for u in urls if u and u.startswith(('https://','http://'))]
                if not urls:raise RuntimeError('部分图片缺少可用地址，任务未完成。')
                target=folder/f'{index:02d}.image'
                retrieve(urls[0],target,ua,referer)
                with target.open('rb') as image: magic=image.read(16)
                ext='.png' if magic.startswith(b'\x89PNG') else '.jpg' if magic.startswith(b'\xff\xd8') else '.gif' if magic.startswith(b'GIF8') else '.webp' if magic.startswith(b'RIFF') else '.image'
                if ext!='.image':os.replace(target,target.with_suffix(ext))
            print(f'[图文] 已保存 {len(images)} 张图片，点击打开目录查看。',flush=True)
        else:
            candidates=media_candidates(video,platform)
            if not candidates:raise RuntimeError('网页中未找到可下载的视频，请确认作品能正常播放。')
            destination=Path(output)/(safe+'-['+ident+'].mp4')
            # Stage and validate before replacing anything. Preserve existing user media.
            if destination.exists():
                destination=destination.with_name(destination.stem+'-'+time.strftime('%H%M%S')+'.mp4')
            staging=destination.with_suffix('.incoming')
            error=None
            for link in candidates:
                try:
                    retrieve(link,staging,ua,referer)
                    probe=subprocess.run([str(Path(root)/'ffmpeg/bin/ffprobe.exe'),'-v','error','-select_streams','v:0','-show_entries','stream=codec_type','-of','csv=p=0',str(staging)],capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
                    if probe.returncode or b'video' not in probe.stdout:
                        staging.unlink(missing_ok=True)
                        raise RuntimeError('媒体文件不完整，无法识别视频流。')
                    os.replace(staging,destination)
                    error=None;break
                except Exception as exc:
                    staging.unlink(missing_ok=True)
                    error=exc
            if error:raise RuntimeError('视频地址暂时不可用，请稍后重试。')
            print('[download] 100%  视频已保存并通过格式检查。',flush=True)
        return context.cookies()
    finally:
        context.close()
