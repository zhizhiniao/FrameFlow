"""Behavior checks for preview/selected media restoration; no WeChat needed."""
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import wechat_capture as w

FF = Path(__file__).resolve().parents[2] / 'ffmpeg/bin'


class Response(io.BytesIO):
    def __init__(self, data, status, total):
        super().__init__(data)
        self.status = status
        self.headers = {'Content-Length': str(total), 'X-enclen': str(w.PREFIX)}


class CaptureChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.folder = Path(cls.temp.name)
        cls.video = cls.folder/'source.mp4'
        subprocess.run([str(FF/'ffmpeg.exe'), '-y', '-v', 'error', '-f', 'lavfi', '-i',
            'testsrc2=size=640x360:rate=25', '-t', '4', '-c:v', 'libx264', '-preset', 'ultrafast',
            '-crf', '18', '-movflags', '+faststart', str(cls.video)], check=True,
            creationflags=w.NO_WINDOW)
        cls.plain = cls.video.read_bytes()
        assert len(cls.plain) > w.PREFIX
        cls.prefix = cls.plain[:w.PREFIX]
        cls.cipher = b'\xa5'*w.PREFIX + cls.plain[w.PREFIX:]
        cls.url = 'https://finder.video.qq.com/251/20302/stodownload?encfilekey=fixture&token=fixture&sign=fixture&X-snsvideoflag=xWT111'

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def remote(self, url, method='GET', headers=None):
        data = b'' if method == 'HEAD' else self.cipher
        return Response(data, 206 if headers and 'Range' in headers else 200, len(self.cipher))

    def prepare(self, name):
        target = self.folder/name
        target.mkdir(exist_ok=True)
        with patch.object(w, 'request', self.remote):
            return w.prepare('fixture', self.url, {w.digest(self.prefix): self.prefix}, target,
                             FF/'ffmpeg.exe', FF/'ffprobe.exe')

    def test_selected_preview_and_saved_bytes_are_identical(self):
        c = self.prepare('good')
        self.assertTrue(Path(c['cover']).stat().st_size > 100)
        self.assertEqual((c['width'], c['height']), (640, 360))
        args = types.SimpleNamespace(manifest=c['manifest'], output=self.folder/'saved',
                ffmpeg=FF/'ffmpeg.exe', ffprobe=FF/'ffprobe.exe', cancel=None)
        with patch.object(w, 'request', self.remote):
            self.assertEqual(w.save(args), 0)
        saved = list(Path(args.output).glob('*.mp4'))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_bytes(), self.plain)
        self.assertFalse(list(Path(args.output).glob('*.partial')))

    def test_corrupt_prefix_never_reaches_download(self):
        c = self.prepare('bad')
        prefix = Path(c['manifest']).parent/'prefix.bin'
        prefix.write_bytes(b'broken')
        args = types.SimpleNamespace(manifest=c['manifest'], output=self.folder/'bad-output',
                ffmpeg=FF/'ffmpeg.exe', ffprobe=FF/'ffprobe.exe', cancel=None)
        with patch.object(w, 'request') as remote:
            with self.assertRaises(w.CaptureError):
                w.save(args)
            remote.assert_not_called()

    def test_wrong_header_rejected_before_preview(self):
        target = self.folder/'wrong'
        target.mkdir()
        wrong = bytearray(self.prefix)
        # Alter top-level moov length so mdat no longer agrees with remote size.
        pos = int.from_bytes(wrong[:4], 'big')
        wrong[pos:pos+4] = (1000).to_bytes(4, 'big')
        with patch.object(w, 'request', self.remote):
            with self.assertRaises(w.CaptureError):
                w.prepare('wrong', self.url, {w.digest(wrong): bytes(wrong)}, target,
                          FF/'ffmpeg.exe', FF/'ffprobe.exe')
        self.assertFalse(list(target.rglob('media.private.json')))

    def test_media_quality_and_identity_survive_heap_suffix(self):
        key, url = w.media_url(self.url+',garbage}')
        self.assertIn('X-snsvideoflag=xWT111', url)
        self.assertNotIn('garbage', url)
        self.assertEqual(key, w.media_url(self.url)[0])
        self.assertIsNone(w.media_url(self.url.replace('finder.video.qq.com', 'finder.video.qq.com.attacker.test')))

    def test_watcher_baseline_waits_for_new_media_and_stops(self):
        session = self.folder/'watch'
        args = types.SimpleNamespace(session=session, ffmpeg=FF/'ffmpeg.exe', ffprobe=FF/'ffprobe.exe')
        old = {'old': self.url}
        new = {**old, 'new': self.url}
        fake = types.SimpleNamespace(snapshot=unittest.mock.Mock(side_effect=[(old, {}, 1, 1), (new, {}, 1, 1)]))
        candidate = {'id': 'new', 'cover': 'cover.jpg', 'manifest': 'media.private.json'}
        def stop(_):
            (session/'stop').write_text('stop')
        with patch.object(w, 'Memory', return_value=fake), patch.object(w, 'prepare', return_value=candidate) as prepare, patch.object(w.time, 'sleep', side_effect=stop):
            self.assertEqual(w.watch(args), 0)
        self.assertEqual(prepare.call_count, 1)
        self.assertEqual(prepare.call_args.args[0], 'new')
        state = json.loads((session/'state.json').read_text(encoding='utf8'))
        self.assertEqual(state['phase'], 'stopped')
        self.assertEqual([c['id'] for c in state['candidates']], ['new'])


if __name__ == '__main__':
    unittest.main()
