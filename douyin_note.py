#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抖音图文/图集下载：用 headless 浏览器自动签名（sdk-glue），抓图集原图。"""
import sys
import os
import json
import re
import urllib.request
from playwright.sync_api import sync_playwright

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36'


def resolve_aweme_id(url):
    """解析短链/长链/纯 id -> aweme_id"""
    if re.fullmatch(r'\d+', url or ''):
        return url
    if not url.startswith('http'):
        url = 'https://' + url
    m = re.search(r'/(?:note|video)/(\d+)', url)
    if m:
        return m.group(1)
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        final = resp.geturl()
        m = re.search(r'/(?:note|video)/(\d+)', final)
        if m:
            return m.group(1)
    except Exception:
        pass
    raise ValueError('无法解析链接，请直接给 note/video 的 aweme_id')


def fetch_detail(aweme_id, ctx):
    """Reuse the managed platform session; no anonymous second browser."""
    page = ctx.new_page()
    try:
        page.goto('https://www.douyin.com/', wait_until='domcontentloaded', timeout=60000)
        page.wait_for_timeout(3000)
        result = page.evaluate("""async (id) => {
            const q = 'device_platform=webapp&aid=6383&channel=channel_pc_web&pc_client_type=1&version_code=170400&version_name=17.4.0&cookie_enabled=true&screen_width=1440&screen_height=900&browser_language=zh-CN&browser_platform=Win32&browser_name=Chrome&browser_version=138.0.0.0&browser_online=true&engine_name=Blink&engine_version=138.0.0.0&os_name=Windows&os_version=10&cpu_core_num=2&device_memory=8&platform=PC&downlink=10&effective_type=4g&round_trip_time=100&aweme_id=' + id;
            const resp = await fetch('https://www.douyin.com/aweme/v1/web/aweme/detail/?' + q, { credentials: 'include' });
            return { status: resp.status, body: await resp.text() };
        }""", aweme_id)
    finally:
        page.close()
    return result


def download(url, outdir, ctx):
    aweme_id = resolve_aweme_id(url)
    print(f'[图文] 解析到 aweme_id: {aweme_id}')
    print('[图文] 启动浏览器签名抓取...')

    result = fetch_detail(aweme_id, ctx)
    if result.get('status') != 200:
        print(f"[图文] 接口返回 {result.get('status')}，可能触发风控，请稍后重试")
        sys.exit(1)

    data = json.loads(result['body'])
    aw = data.get('aweme_detail', {})
    if not aw:
        print('[图文] 未拿到作品数据，可能链接失效')
        sys.exit(1)

    desc = aw.get('desc', '').strip()
    images = aw.get('images', [])

    safe = re.sub(r'[\\/:*?"<>|\r\n\t]+', '_', desc).strip(' ._') if desc else aweme_id
    if len(safe) > 60:
        safe = safe[:60].rstrip(' ._')
    d = os.path.join(outdir, safe)
    os.makedirs(d, exist_ok=True)

    print(f'[图文] 标题：{desc}')
    if images:
        def dl(u, fname):
            try:
                req = urllib.request.Request(u, headers={
                    'User-Agent': UA, 'Referer': 'https://www.douyin.com/'})
                with urllib.request.urlopen(req, timeout=120) as resp:
                    open(fname, 'wb').write(resp.read())
                return True
            except Exception as e:
                print(f'[图文] 下载失败 {os.path.basename(fname)}: {e}')
                return False

        is_live = any(im.get('video') for im in images)
        kind = '动图' if is_live else '图片'
        print(f'[图文] {kind} {len(images)} 张，开始下载...')
        ok = 0
        for i, im in enumerate(images, 1):
            done = False
            v = im.get('video')
            if v:
                addr = v.get('play_addr') or v.get('download_addr') or {}
                urls = addr.get('url_list') or []
                if urls:
                    done = dl(urls[0], os.path.join(d, f'{i:02d}.mp4'))
            if not done:
                urls = im.get('url_list') or []
                if urls:
                    u0 = urls[0].lower()
                    ext = 'webp'
                    if 'png' in u0:
                        ext = 'png'
                    elif 'jpeg' in u0 or 'jpg' in u0:
                        ext = 'jpg'
                    done = dl(urls[0], os.path.join(d, f'{i:02d}.{ext}'))
            if done:
                ok += 1
        info = f'标题：{desc}\n来源：{url}\n{kind}：{ok}/{len(images)} 张\n'
        open(os.path.join(d, '文章信息.txt'), 'w', encoding='utf-8').write(info)
        print(f'[图文] 完成：{ok}/{len(images)} 张，目录：{d}')
        return 0 if ok == len(images) else 1
    else:
        video = aw.get('video', {})
        if video:
            print('[图文] 这是视频，请用视频下载方式（该链接非图文）')
        else:
            print('[图文] 该作品无图片也无视频，可能已删除')
        sys.exit(2)


