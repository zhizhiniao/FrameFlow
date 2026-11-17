import argparse
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import frameflow_worker as w

class PlatformBehavior(unittest.TestCase):
    def test_instagram_routes_only_its_own_domains(self):
        self.assertEqual(w.resolve_platform('auto','https://www.instagram.com/reel/test/'),'instagram')
        self.assertEqual(w.resolve_platform('auto','https://instagram.com.attacker.test/p/test/'),'auto')
        self.assertEqual(w.resolve_platform('auto','https://vimeo.com/1'),'auto')

    def test_instagram_requires_scoped_session_not_guest_cookie(self):
        c=lambda domain,name:dict(domain=domain,name=name,value='synthetic',expires=-1)
        self.assertFalse(w.has_auth([c('.instagram.com','csrftoken')],'instagram'))
        self.assertFalse(w.has_auth([c('.example.com','sessionid')],'instagram'))
        self.assertTrue(w.has_auth([c('.instagram.com','sessionid')],'instagram'))

    def test_instagram_login_error_requests_one_queue_login_and_cleans_cookie_file(self):
        with tempfile.TemporaryDirectory() as data:
            cookie=dict(domain='.instagram.com',name='sessionid',value='synthetic',expires=-1,path='/',secure=True)
            args=argparse.Namespace(data=data,platform='instagram',url='https://www.instagram.com/reel/test/',output=str(Path(data)/'out'))
            proc=MagicMock(); proc.__enter__.return_value=proc
            proc.stdout=io.StringIO('ERROR: You need to log in to access this content\n');proc.wait.return_value=1
            with patch.object(w,'download_cookies',return_value=[cookie]),patch.object(w,'node_path',return_value='node.exe'),patch.object(w.subprocess,'Popen',return_value=proc) as popen:
                self.assertEqual(w.download(args),10)
                command=popen.call_args.args[0]
                self.assertIn('--cookies',command)
                self.assertEqual(command[-1],args.url)
            self.assertEqual(list((Path(data)/'temp').glob('session-*.txt')),[])

if __name__=='__main__': unittest.main()
