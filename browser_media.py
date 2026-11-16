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
    details={}
    def observe(response):
        try:
            parsed=urllib.parse.urlsplit(response.url)
            if platform=='douyin' and parsed.hostname=='www.douyin.com' and parsed.path=='/aweme/v1/web/aweme/detail/':
                body=response.json().get('aweme_detail')
                if body and body.get('aweme_id'):details[str(body['aweme_id'])]=body
        except Exception:pass
    context.on('response',observe)
    try:
        page=context.pages[0] if context.pages else context.new_page()
        print('[解析] 正在使用本机登录态打开作品页面…',flush=True)
        page.goto(args.url,wait_until='domcontentloaded',timeout=60000)
        if platform=='douyin':
            page.wait_for_url(re.compile(r'https://[^/]*douyin.com/(video|note)/\d+'),timeout=20000)
            match=re.search(r'/(?:video|note)/(\d+)',page.url)
            ident=match[1]
            deadline=time.monotonic()+20
            while ident not in details and time.monotonic()<deadline:
                page.wait_for_timeout(400)
            item=details.get(ident)
            if not item:raise RuntimeError('作品页面未返回媒体信息。请确认作品可播放，或重新登录后重试。')
            title=item.get('desc') or ident
            images=item.get('images') or []
            video=item.get('video') or {}
        else:
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
