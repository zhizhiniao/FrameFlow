"""Exercise browser parsing through the real download entry with synthetic responses."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import browser_media as m

IDENT = '1234567890123456789'
URL = 'https://www.douyin.com/video/' + IDENT
ITEM = {'aweme_id': IDENT, 'desc': 'fixture', 'video': {
    'play_addr': {'url_list': ['https://media.example/video.mp4']}}}


class Response:
    def __init__(self, body=None, status=200, broken=False):
        self.url = 'https://www.douyin.com/aweme/v1/web/aweme/detail/?signature=PRIVATE'
        self.status = status
        self.headers = {'content-type': 'text/html' if broken else 'application/json'}
        self.body, self.broken = body, broken

    def json(self):
        if self.broken:
            raise ValueError('SECRET response body at https://example.com/?token=PRIVATE')
        return self.body


class Page:
    def __init__(self, context, attempts):
        self.context, self.attempts = context, attempts
        self.url, self.visits, self.gate = URL, [], None

    def goto(self, url, **kwargs):
        self.visits.append(url)
        step = self.attempts[min(len(self.visits) - 1, len(self.attempts) - 1)]
        self.gate = step.get('gate')
        self.url = step.get('url', URL)
        if step.get('error'):
            raise step['error']
        for event, obj in step.get('events', []):
            for callback in list(self.context.listeners.get(event, [])):
                callback(obj)
        doc = Response(status=step.get('http', 200))
        doc.url = self.url
        return doc

    def wait_for_url(self, *args, **kwargs):
        pass

    def wait_for_timeout(self, ms):
        pass

    def evaluate(self, script, *args):
        return 'Fixture-UA' if script == 'navigator.userAgent' else self.gate


class Context:
    def __init__(self, attempts):
        self.listeners, self.closed = {}, False
        self.pages = [Page(self, attempts)]

    def on(self, event, callback):
        self.listeners.setdefault(event, []).append(callback)

    def remove_listener(self, event, callback):
        self.listeners[event].remove(callback)

    def cookies(self):
        return [{'name': 'synthetic', 'value': 'PRIVATE'}]

    def close(self):
        self.closed = True


class BrowserMedia(unittest.TestCase):
    def run_case(self, attempts):
        ctx = Context(attempts)
        fake = argparse.Namespace(chromium=argparse.Namespace(launch_persistent_context=lambda *a, **k: ctx))
        clock = iter(range(10000))
        self.log, self.error = io.StringIO(), None
        def retrieve(url, destination, *args):
            Path(destination).write_bytes(b'fixture-video')
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(self.log), \
                patch.object(m.time, 'monotonic', side_effect=lambda: next(clock)), \
                patch.object(m, 'retrieve', side_effect=retrieve), \
                patch.object(m.subprocess, 'run', return_value=argparse.Namespace(returncode=0, stdout=b'video')):
            args = argparse.Namespace(platform='douyin', url=URL)
            try:
                m.run(args, fake, 'browser.exe', folder, folder, folder, [])
            except RuntimeError as exc:
                self.error = str(exc)
            self.media_count = len(list(Path(folder).glob('*.mp4')))
        self.assertTrue(ctx.closed)
        self.assertNotIn('PRIVATE', self.log.getvalue() + (self.error or ''))
        self.assertNotIn('SECRET', self.log.getvalue() + (self.error or ''))
        return ctx.pages[0]

    def test_transient_missing_response_retries_same_session_and_succeeds(self):
        page = self.run_case([{}, {'events': [('response', Response({'aweme_detail': ITEM}))]}])
        self.assertIsNone(self.error)
        self.assertEqual(len(page.visits), 2)
        self.assertEqual(self.media_count, 1)
        self.assertIn('[重试]', self.log.getvalue())

    def test_permanent_http_failure_stops_after_three_and_explains(self):
        page = self.run_case([{'events': [('response', Response({}, status=503))]}])
        self.assertEqual(len(page.visits), 3)
        self.assertIn('503', self.error)
        self.assertIn('3', self.error)
        self.assertNotIn('重新登录', self.error)
        self.assertEqual(self.media_count, 0)

    def test_non_json_is_reported_without_response_body_or_signed_url(self):
        self.run_case([{'events': [('response', Response(broken=True))]}])
        self.assertIn('JSON', self.error)
        self.assertIn('HTTP 200', self.log.getvalue())

    def test_missing_detail_records_business_code_and_ignores_raw_message(self):
        self.run_case([{'events': [('response', Response({'status_code': 1234, 'status_msg': 'PRIVATE'}))]}])
        self.assertIn('1234', self.error)
        self.assertIn('aweme_detail', self.error)

    def test_wrong_video_is_never_saved(self):
        other = dict(ITEM, aweme_id='111')
        self.run_case([{'events': [('response', Response({'aweme_detail': other}))]}])
        self.assertIsNotNone(self.error)
        self.assertEqual(self.media_count, 0)
        self.assertIn('ID', self.error)

    def test_empty_media_is_retried_before_any_file_is_written(self):
        page = self.run_case([{'events': [('response', Response({'aweme_detail': {'aweme_id': IDENT}}))]},
                              {'events': [('response', Response({'aweme_detail': ITEM}))]}])
        self.assertIsNone(self.error)
        self.assertEqual(len(page.visits), 2)
        self.assertEqual(self.media_count, 1)

    def test_visible_verification_stops_without_relogin_or_automatic_retry(self):
        page = self.run_case([{'gate': 'verification'}])
        self.assertEqual(len(page.visits), 1)
        self.assertIn('验证', self.error)
        self.assertNotIn('重新登录', self.error)

    def test_deleted_work_stops_without_retry(self):
        page = self.run_case([{'gate': 'unavailable'}])
        self.assertEqual(len(page.visits), 1)
        self.assertIn('下架', self.error)

    def test_http_403_with_visible_verification_is_not_retried(self):
        page = self.run_case([{'http': 403, 'gate': 'verification'}])
        self.assertEqual(len(page.visits), 1)
        self.assertIn('验证', self.error)
        self.assertIn('HTTP 403', self.log.getvalue())

    def test_network_failure_is_retried_and_logs_only_error_code(self):
        class NetworkError(m.BrowserError):
            pass
        page = self.run_case([{'error': NetworkError('net::ERR_CONNECTION_RESET https://douyin.com/?token=PRIVATE')},
                              {'events': [('response', Response({'aweme_detail': ITEM}))]}])
        self.assertIsNone(self.error)
        self.assertEqual(len(page.visits), 2)
        self.assertIn('ERR_CONNECTION_RESET', self.log.getvalue())

    def test_success_does_not_retry(self):
        page = self.run_case([{'events': [('response', Response({'aweme_detail': ITEM}))]}])
        self.assertIsNone(self.error)
        self.assertEqual(len(page.visits), 1)
        self.assertNotIn('[重试]', self.log.getvalue())

    def test_failed_detail_request_is_logged_and_retried(self):
        request = argparse.Namespace(url=Response().url, failure='net::ERR_CONNECTION_RESET')
        page = self.run_case([{'events': [('requestfailed', request)]},
                              {'events': [('response', Response({'aweme_detail': ITEM}))]}])
        self.assertIsNone(self.error)
        self.assertEqual(len(page.visits), 2)
        self.assertIn('ERR_CONNECTION_RESET', self.log.getvalue())

    def test_only_explicit_login_gate_mentions_account_update(self):
        page = self.run_case([{'gate': 'login'}])
        self.assertEqual(len(page.visits), 1)
        self.assertIn('明确要求登录', self.error)

    def test_navigation_context_error_records_safe_category_and_stage(self):
        page = self.run_case([{'error': m.BrowserError('Execution context was destroyed https://example.com/?token=PRIVATE')},
                              {'events': [('response', Response({'aweme_detail': ITEM}))]}])
        self.assertIsNone(self.error)
        self.assertEqual(len(page.visits), 2)
        self.assertIn('打开作品页面', self.log.getvalue())
        self.assertIn('执行上下文重建', self.log.getvalue())

    def test_browser_timeout_message_is_not_dumped(self):
        self.run_case([{'error': m.BrowserError('Timeout 30000ms exceeded https://example.com/?token=PRIVATE')}])
        self.assertIn('等待超时', self.error)

    def test_gate_detection_uses_visible_elements_in_real_browser(self):
        import frameflow_worker as w
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=w.browser_path(p), headless=True)
            try:
                page = browser.new_page()
                page.set_content('<p>验证码登录</p><div id="captcha_container" style="display:none">验证</div>')
                self.assertIsNone(m._douyin_gate(page))
                page.set_content('<p>登录</p><div id="captcha_container"></div>')
                self.assertIsNone(m._douyin_gate(page))
                page.set_content('<div id="captcha_container">安全验证</div>')
                self.assertEqual(m._douyin_gate(page), 'verification')
                page.set_content('<p>作品已下架</p>')
                self.assertEqual(m._douyin_gate(page), 'unavailable')
            finally:
                browser.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
