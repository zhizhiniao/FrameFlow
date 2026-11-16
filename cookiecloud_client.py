"""CookieCloud client: decrypt locally and return only the requested platform cookies."""
import base64
import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from Cryptodome.Cipher import AES
from Cryptodome.Util.Padding import unpad


def decrypt(config, response):
    raw = base64.b64decode(response['encrypted'], validate=True)
    password = hashlib.md5((config['uuid'] + '-' + config['password']).encode()).hexdigest()[:16].encode()
    kind = response.get('crypto_type') or config.get('crypto_type') or 'legacy'
    if kind == 'aes-128-cbc-fixed':
        key, iv, payload = password, bytes(16), raw
    elif kind == 'legacy' and raw[:8] == b'Salted__':
        salt = raw[8:16]; material = previous = b''
        while len(material) < 48:
            previous = hashlib.md5(previous + password + salt).digest()
            material += previous
        key, iv, payload = material[:32], material[32:48], raw[16:]
    else:
        raise ValueError('Unsupported encryption format')
    return json.loads(unpad(AES.new(key, AES.MODE_CBC, iv).decrypt(payload), 16))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # The configured endpoint alone receives the sync identifier and optional headers.
        raise RuntimeError('CookieCloud 地址发生跳转，请更新为服务的最终地址。')


def fetch_cookies(config, domains):
    endpoint = config.get('endpoint', '').strip().rstrip('/')
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RuntimeError('CookieCloud 服务地址格式不正确。')
    if not config.get('uuid') or not config.get('password'):
        raise RuntimeError('CookieCloud 连接配置不完整。')
    url = endpoint + '/get/' + urllib.parse.quote(config['uuid'], safe='')
    headers = {'Accept': 'application/json'}
    for key, value in (config.get('request_headers') or {}).items():
        if '\n' in key + value or '\r' in key + value:
            raise RuntimeError('CookieCloud 请求头格式不正确。')
        headers[key] = value
    try:
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(urllib.request.Request(url, headers=headers), timeout=20) as response:
            raw = response.read(32 * 1024 * 1024 + 1)
        if len(raw) > 32 * 1024 * 1024:
            raise RuntimeError('CookieCloud 同步数据过大，请减少扩展中的同步范围。')
        payload = decrypt(config, json.loads(raw))
    except RuntimeError:
        raise
    except (urllib.error.URLError, TimeoutError, OSError):
        raise RuntimeError('无法连接 CookieCloud，请确认同步服务正在运行后重试。') from None
    except Exception:
        raise RuntimeError('CookieCloud 数据无法解密，请检查同步配置或在扩展中重新同步。') from None
    result = []
    for group in payload.get('cookie_data', {}).values():
        if not isinstance(group, list): continue
        for cookie in group:
            host = cookie.get('domain', '').lstrip('.').lower()
            if not any(host == domain or host.endswith('.' + domain) for domain in domains): continue
            expires = cookie.get('expirationDate', cookie.get('expires', -1)) or -1
            if expires > 0 and expires <= time.time(): continue
            if not cookie.get('name') or not cookie.get('value'): continue
            result.append(dict(name=cookie['name'], value=cookie['value'], domain=cookie['domain'],
                path=cookie.get('path', '/'), expires=expires, secure=bool(cookie.get('secure')),
                httpOnly=bool(cookie.get('httpOnly'))))
    return result, payload.get('update_time')
