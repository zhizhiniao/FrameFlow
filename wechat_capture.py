"""FrameFlow's separate local WeChat media capture engine (GPL-3.0).

MP4 header recovery is adapted from laoyu20032003/wx_video_downloader,
commit 6785dccc8d0243176bd2ece36ad596c989b751d7 (MemScan.cs, wx-dl.ps1).
Only media URLs and MP4 prefixes are read; no process writes, hooks or proxy.
See licenses/WechatCapture-GPL-3.0.txt and source/WECHAT-SOURCE.md.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

PREFIX = 131072
URL_RE = re.compile(rb'https?://finder\.video\.qq\.com/[\x21\x23-\x26\x28-\x3b\x3d\x3f-\x5b\x5d-\x7e]{30,4000}')
NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


class CaptureError(RuntimeError):
    pass


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.new')
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    os.replace(temp, path)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def media_url(raw):
    try:
        text = raw.decode('ascii') if isinstance(raw, bytes) else raw
        text = text.replace('&amp;', '&').split('"', 1)[0]
        u = urllib.parse.urlsplit(text)
        if u.hostname != 'finder.video.qq.com' or u.scheme != 'https' or '/stodownload' not in u.path:
            return None
        q = urllib.parse.parse_qs(u.query)
        if not all(q.get(k) for k in ('encfilekey', 'token', 'sign')):
            return None
        # Some heap strings continue into the next record. Remove that suffix;
        # this optional flag is not part of the CDN signature.
        for key in ('X-snsvideoflag',):
            if key in q:
                m = re.match(r'xWT\d+|[A-Za-z0-9_-]{1,24}', q[key][0])
                q[key] = [m.group() if m else '0']
        # Remove diagnostics accidentally appended after the URL, not auth fields.
        q.pop('_pUid_', None)
        normalized = urllib.parse.urlunsplit((u.scheme, u.netloc, u.path,
                     urllib.parse.urlencode(q, doseq=True), ''))
        return digest((u.path + '|' + q['encfilekey'][0]).encode())[:24], normalized
    except (ValueError, UnicodeError):
        return None


def moov_end(header):
    pos = 0
    for _ in range(6):
        if pos + 8 > len(header):
            return 0
        size, kind = struct.unpack_from('>I4s', header, pos)
        if not 8 <= size <= 32 * 1024 * 1024:
            return 0
        if kind == b'moov':
            return pos + size
        if kind not in (b'ftyp', b'free', b'wide', b'uuid', b'skip', b'styp', b'sidx'):
            return 0
        pos += size
    return 0


def layout_matches(data, total):
    """Check top-level boxes against the actual remote size, not a guessed head."""
    pos = 0
    has_moov = False
    for _ in range(20):
        if pos + 8 > len(data):
            return False
        size, kind = struct.unpack_from('>I4s', data, pos)
        if size == 1:
            if pos + 16 > len(data):
                return False
            size = struct.unpack_from('>Q', data, pos + 8)[0]
        elif size == 0:
            size = total - pos
        if size < 8 or pos + size > total:
            return False
        if kind == b'moov':
            has_moov = True
        if kind == b'mdat':
            return has_moov and 0 <= total - (pos + size) <= 1024
        if kind not in (b'ftyp', b'moov', b'free', b'wide', b'uuid', b'skip', b'styp', b'sidx'):
            return False
        pos += size
    return False


class Memory:
    class MBI(ctypes.Structure):
        _fields_ = [('base', ctypes.c_void_p), ('allocation', ctypes.c_void_p),
                    ('allocation_protect', wt.DWORD), ('size', ctypes.c_size_t),
                    ('state', wt.DWORD), ('protect', wt.DWORD), ('kind', wt.DWORD)]

    class PE(ctypes.Structure):
        _fields_ = [('size', wt.DWORD), ('usage', wt.DWORD), ('pid', wt.DWORD),
                    ('heap', ctypes.c_size_t), ('module', wt.DWORD), ('threads', wt.DWORD),
                    ('parent', wt.DWORD), ('priority', wt.LONG), ('flags', wt.DWORD),
                    ('name', wt.WCHAR * 260)]

    def __init__(self, cancel=None):
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        self.k.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
        self.k.OpenProcess.restype = wt.HANDLE
        self.k.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        self.k.ReadProcessMemory.restype = wt.BOOL
        self.k.VirtualQueryEx.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        self.k.VirtualQueryEx.restype = ctypes.c_size_t
        self.k.CreateToolhelp32Snapshot.argtypes = [wt.DWORD, wt.DWORD]
        self.k.CreateToolhelp32Snapshot.restype = wt.HANDLE
        self.k.Process32FirstW.argtypes = [wt.HANDLE, ctypes.POINTER(self.PE)]
        self.k.Process32NextW.argtypes = [wt.HANDLE, ctypes.POINTER(self.PE)]
        self.k.CloseHandle.argtypes = [wt.HANDLE]
        self.cancel = Path(cancel) if cancel else None

    def stopped(self):
        return bool(self.cancel and self.cancel.exists())

    def processes(self):
        h = self.k.CreateToolhelp32Snapshot(2, 0)
        if h == ctypes.c_void_p(-1).value:
            raise CaptureError('无法读取微信进程列表，请重试。')
        entries = []
        pe = self.PE()
        pe.size = ctypes.sizeof(pe)
        try:
            ok = self.k.Process32FirstW(h, ctypes.byref(pe))
            while ok:
                entries.append((pe.pid, pe.parent, pe.name.lower()))
                ok = self.k.Process32NextW(h, ctypes.byref(pe))
        finally:
            self.k.CloseHandle(h)
        hosts = {p for p, _, name in entries if name in ('weixin.exe', 'wechat.exe')}
        children = set(hosts)
        for _ in range(4):
            children.update(p for p, parent, _ in entries if parent in children)
        return [p for p, _, n in entries if n == 'wechatappex.exe' and p in children]

    def read(self, handle, address, size):
        buf = ctypes.create_string_buffer(size)
        got = ctypes.c_size_t()
        if not self.k.ReadProcessMemory(handle, ctypes.c_void_p(address), buf, size, ctypes.byref(got)):
            return b''
        return buf.raw[:got.value]

    def snapshot(self):
        urls, heads = {}, {}
        pids = self.processes()
        accessible = 0
        for pid in pids:
            if self.stopped():
                break
            handle = self.k.OpenProcess(0x410, False, pid)
            if not handle:
                continue
            accessible += 1
            pos, count = 65536, 0
            try:
                # GPU and utility processes do not own decoded MP4 buffers.
                # Query metadata once, rather than scanning their large heaps.
                needed = wt.ULONG()
                nt = ctypes.WinDLL('ntdll').NtQueryInformationProcess
                nt.argtypes = [wt.HANDLE, wt.ULONG, ctypes.c_void_p, wt.ULONG, ctypes.POINTER(wt.ULONG)]
                nt(handle, 60, None, 0, ctypes.byref(needed))
                if 0 < needed.value < 65536:
                    command = ctypes.create_string_buffer(needed.value)
                    if nt(handle, 60, command, len(command), ctypes.byref(needed)) == 0:
                        pointer_offset = 8 if ctypes.sizeof(ctypes.c_void_p) == 8 else 4
                        address = ctypes.c_void_p.from_buffer(command, pointer_offset).value
                        text = ctypes.wstring_at(address, wt.USHORT.from_buffer(command).value//2)
                        if '--type=gpu-process' in text or '--type=utility' in text:
                            continue
                while pos < 0x7fffffffffff and not self.stopped():
                    mbi = self.MBI()
                    if not self.k.VirtualQueryEx(handle, ctypes.c_void_p(pos), ctypes.byref(mbi), ctypes.sizeof(mbi)):
                        break
                    base, size = mbi.base or pos, mbi.size
                    if not size:
                        break
                    pos = base + size
                    if mbi.state != 0x1000 or mbi.protect & 0x101 or mbi.kind == 0x100000:
                        continue
                    for offset in range(0, size, 8 * 1024 * 1024):
                        if self.stopped():
                            break
                        data = self.read(handle, base + offset, min(size-offset, 8*1024*1024+PREFIX))
                        for match in URL_RE.finditer(data):
                            parsed = media_url(match.group())
                            if parsed:
                                key, url = parsed
                                urls[key] = url
                        start = 0
                        while count < 40:
                            index = data.find(b'ftyp', start)
                            if index < 4:
                                break
                            start = index + 4
                            length = struct.unpack_from('>I', data, index - 4)[0]
                            if 16 <= length <= 512:
                                prefix = data[index-4:index-4+PREFIX]
                                if len(prefix) < PREFIX and moov_end(prefix):
                                    prefix = self.read(handle, base + offset + index - 4, PREFIX)
                                if len(prefix) == PREFIX and moov_end(prefix):
                                    heads[digest(prefix)] = prefix
                                    count += 1
            finally:
                self.k.CloseHandle(handle)
        return urls, heads, len(pids), accessible


def opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(url, method='GET', headers=None):
    h = {'Referer': 'https://liteapp.weixin.qq.com/', 'User-Agent': 'Mozilla/5.0'}
    h.update(headers or {})
    try:
        return opener().open(urllib.request.Request(url, method=method, headers=h), timeout=12)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403, 410):
            raise CaptureError('视频地址已过期，请重新播放后再次抓取。') from None
        raise CaptureError('媒体请求未完成，请继续播放后重试。') from None
    except (OSError, ValueError):
        raise CaptureError('媒体连接失败，请检查网络或重新播放。') from None


def command_run(command, timeout=35, cancel=None):
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          creationflags=NO_WINDOW) as proc:
        began = time.monotonic()
        while True:
            try:
                out, err = proc.communicate(timeout=0.25)
                return proc.returncode, out, err
            except subprocess.TimeoutExpired:
                if (cancel and Path(cancel).exists()) or time.monotonic()-began > timeout:
                    proc.kill()
                    proc.communicate()
                    raise CaptureError('操作已取消。' if cancel and Path(cancel).exists() else '媒体校验超时，请稍后重试。')


def probe(path, ffprobe):
    code, out, _ = command_run([str(ffprobe), '-v', 'error', '-show_entries',
        'format=duration:stream=codec_type,width,height', '-of', 'json', str(path)])
    try:
        value = json.loads(out)
        video = next(s for s in value['streams'] if s.get('codec_type') == 'video')
        return {'duration': float(value['format']['duration']), 'width': int(video['width']), 'height': int(video['height'])}
    except (ValueError, KeyError, StopIteration):
        raise CaptureError('未取得可用视频信息，请让视频继续播放。') from None


def prepare(key, url, heads, session, ffmpeg, ffprobe, cancel=None):
    with request(url, 'HEAD') as res:
        total = int(res.headers.get('Content-Length', 0))
        enclen = int(res.headers.get('X-enclen', PREFIX))
    if not PREFIX == enclen or total <= enclen:
        raise CaptureError('此视频的媒体格式暂不支持。')
    usable = [(h, p) for h, p in heads.items() if 0 < moov_end(p) < 8*1024*1024]
    if not usable:
        raise CaptureError('等待微信解码，请继续播放目标视频。')
    span = min(total, max(2*1024*1024, max(moov_end(p) for _, p in usable) + 1024*1024))
    with request(url, headers={'Range': 'bytes=0-%d' % (span-1)}) as res:
        if res.status != 206 and total > span:
            raise CaptureError('此视频暂不支持快速预览，请重播后重试。')
        encrypted = res.read(span)
    folder = Path(session) / key
    folder.mkdir(exist_ok=True)
    partial = folder / 'preview.part.mp4'
    image = folder / 'cover.jpg'
    for fingerprint, prefix in usable:
        if cancel and Path(cancel).exists():
            raise CaptureError('操作已取消。')
        repaired = prefix + encrypted[enclen:]
        if not layout_matches(repaired, total):
            continue
        partial.write_bytes(repaired)
        try:
            info = probe(partial, ffprobe)
            code, _, _ = command_run([str(ffmpeg), '-y', '-nostdin', '-v', 'error', '-i', str(partial),
                '-frames:v', '1', '-vf', 'scale=320:-2', str(image)], cancel=cancel)
            if code or not image.is_file() or image.stat().st_size < 100:
                continue
        except CaptureError:
            continue
        prefix_path = folder / 'prefix.bin'
        prefix_path.write_bytes(prefix)
        manifest = {'schema': 1, 'id': key, 'url': url, 'total': total, 'enclen': enclen,
                    'prefix_sha256': fingerprint, 'created': time.time(), **info}
        manifest_path = folder / 'media.private.json'
        atomic_json(manifest_path, manifest)
        partial.unlink(missing_ok=True)
        return {'id': key, 'cover': str(image), 'manifest': str(manifest_path), 'size': total,
                'label': '%d:%02d · %d×%d · %.1f MB' % (info['duration']//60, info['duration']%60, info['width'], info['height'], total/1048576), **info}
    partial.unlink(missing_ok=True)
    raise CaptureError('等待匹配的解密数据，请继续播放目标视频。')


def watch(args):
    session = Path(args.session).resolve()
    session.mkdir(parents=True, exist_ok=True)
    cancel = session / 'stop'
    state_path = session / 'state.json'
    memory = Memory(cancel)
    candidates, pending, attempts, ready = {}, {}, {}, set()
    def state(phase, message):
        atomic_json(state_path, {'phase': phase, 'message': message,
                    'candidates': list(candidates.values()), 'updated': time.time()})
    state('baseline', '正在准备抓取，请稍候…')
    urls, heads, count, accessible = memory.snapshot()
    baseline, base_heads = set(urls), set(heads)
    initial_heads = set(heads)
    state('watching', '抓取已开启。请现在到微信打开并播放一条新视频。')
    rounds = 0
    while not cancel.exists():
        began = time.monotonic()
        urls, heads, count, accessible = memory.snapshot()
        rounds += 1
        if not count:
            state('watching', '未发现视频号窗口，请打开电脑版微信并播放目标视频。')
        elif not accessible:
            state('watching', '无法读取微信媒体进程，请确认微信与帧流使用相同的运行权限。')
        else:
            for key, url in urls.items():
                if key not in baseline and key not in ready:
                    pending[key] = url
            # New plaintext heads can also be a previously preloaded video.
            # That is a candidate, never an assertion about the current video.
            if set(heads)-base_heads:
                for key, url in urls.items():
                    if key not in ready:
                        pending.setdefault(key, url)
                base_heads.update(heads)
            status = '等待新视频。请播放目标视频，保持播放直到封面出现。'
            due = [(key, url) for key, url in pending.items() if attempts.get(key, 0) <= time.monotonic()]
            for key, url in due[:4]:
                if cancel.exists():
                    break
                pending.pop(key, None)
                state('preview', '已检测到媒体，正在匹配并生成封面…')
                try:
                    selected_heads = {h: p for h, p in heads.items() if key not in baseline or h not in initial_heads}
                    candidate = prepare(key, url, selected_heads, session, args.ffmpeg, args.ffprobe, cancel)
                    candidates[key] = candidate
                    ready.add(key)
                    pending.pop(key, None)
                    status = '发现 %d 条候选。请核对封面，选择需要的视频。' % len(candidates)
                except CaptureError as exc:
                    attempts[key] = time.monotonic() + 12
                    pending[key] = url
                    status = str(exc)
            state('watching', ('已抓取 %d 条候选，可继续播放其他视频。' % len(candidates)) if candidates else status)
        if rounds >= 90:
            state('stopped', '本次抓取已结束。需要继续时请再次点击开始抓取。')
            return 0
        for _ in range(max(1, int((5-(time.monotonic()-began))*4))):
            if cancel.exists():
                break
            time.sleep(0.25)
    state('stopped', '已停止抓取。已取得的候选仍可选择下载。')
    return 0


def save(args):
    manifest_path = Path(args.manifest).resolve()
    value = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    prefix = (manifest_path.parent / 'prefix.bin').read_bytes()
    if value.get('schema') != 1 or len(prefix) != PREFIX or digest(prefix) != value['prefix_sha256']:
        raise CaptureError('预览数据已失效，请重新抓取。')
    if not media_url(value['url']):
        raise CaptureError('媒体地址无效，请重新抓取。')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    partial = output / 'download.partial'
    expected = int(value['total'])
    print('[提示] 正在下载所选视频…', flush=True)
    try:
        received = 0
        last_percent = -1
        with request(value['url']) as res, partial.open('wb') as stream:
            if res.status != 200 or int(res.headers.get('Content-Length', 0)) != expected:
                raise CaptureError('视频地址或清晰度已变化，请重新抓取。')
            while True:
                if args.cancel and Path(args.cancel).exists():
                    raise CaptureError('操作已取消。')
                chunk = res.read(1024*1024)
                if not chunk:
                    break
                stream.write(chunk)
                received += len(chunk)
                percent = min(90, int(received/expected*90))
                if percent != last_percent:
                    print('[download] %d%% 正在保存微信视频号' % percent, flush=True)
                    last_percent = percent
        if received != expected:
            raise CaptureError('下载未完成，请重新播放后抓取。')
        with partial.open('r+b') as stream:
            stream.write(prefix)
        print('[download] 92% 正在校验完整视频，请稍候…', flush=True)
        info = probe(partial, args.ffprobe)
        if abs(info['duration']-float(value['duration'])) > 0.2 or any(info[k] != value[k] for k in ('width', 'height')):
            raise CaptureError('文件与所选预览不一致，请重新抓取。')
        code, _, errors = command_run([str(args.ffmpeg), '-nostdin', '-v', 'error', '-i', str(partial),
                 '-f', 'null', '-'], timeout=900, cancel=args.cancel)
        real_errors = [line for line in errors.decode('utf-8', 'replace').splitlines()
                       if line and not re.search('non monotonically increasing dts|Application provided invalid', line)]
        if code or real_errors:
            raise CaptureError('完整视频校验未通过，请重新播放后抓取。')
        name = '视频号_%s_%dp_%ds_%s.mp4' % (time.strftime('%Y%m%d_%H%M%S'), min(info['width'], info['height']), round(info['duration']), value['id'][:8])
        os.replace(partial, output/name)
        print('[download] 100% 已通过完整校验', flush=True)
        return 0
    finally:
        partial.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['watch', 'save', 'snapshot'])
    parser.add_argument('--session')
    parser.add_argument('--manifest')
    parser.add_argument('--output')
    parser.add_argument('--cancel')
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--ffprobe', required=True)
    args = parser.parse_args()
    try:
        if args.action == 'watch':
            return watch(args)
        if args.action == 'save':
            return save(args)
        urls, heads, count, accessible = Memory().snapshot()
        folder = Path(args.session)
        folder.mkdir(parents=True, exist_ok=True)
        atomic_json(folder/'snapshot.private.json', {'urls': urls, 'heads': list(heads), 'processes': count, 'accessible': accessible})
        for key, prefix in heads.items():
            (folder/(key+'.bin')).write_bytes(prefix)
        print(json.dumps({'media': len(urls), 'headers': len(heads), 'processes': count, 'accessible': accessible}))
        return 0
    except CaptureError as exc:
        print('[错误] '+str(exc), flush=True)
        if args.action == 'watch' and args.session:
            atomic_json(Path(args.session)/'state.json', {'phase': 'error', 'message': str(exc), 'candidates': []})
        return 20
    except Exception:
        print('[错误] 微信媒体处理未完成，请继续播放并重新抓取。', flush=True)
        if args.action == 'watch' and args.session:
            atomic_json(Path(args.session)/'state.json', {'phase': 'error', 'message': '抓取未完成，请重试或检查微信运行状态。', 'candidates': []})
        return 21


if __name__ == '__main__':
    raise SystemExit(main())
