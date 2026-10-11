import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import build
from keyboard_worker import Relay, KeyboardError


class Socket:
    def __init__(self): self.frames=[]; self.response=b''; self.reject=None; self.bad_receipt=False
    def settimeout(self, value): pass
    def sendall(self, data):
        f=json.loads(data); self.frames.append(f)
        r=dict(v=1,id=f['id'],ok=True,session='session-a',document='document-a',receipt='proxy_invoked')
        if self.reject: r.update(ok=False,code=self.reject)
        if self.bad_receipt: r.pop('receipt')
        self.response=json.dumps(r).encode()+b'\n'
    def recv(self, count): r=self.response[:count]; self.response=self.response[count:]; return r


class Device:
    def __init__(self): self.sock=Socket(); self.closed=False
    def create_inner_connection(self, port): assert port==9031; return self
    def get_socket(self): return self.sock
    def close(self): self.closed=True


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.device=Device(); self.targets=[]
        def resolve(target, ports): self.targets.append(target); return self.device
        self.relay=Relay(resolve)
        self.relay.request(dict(id=1,action='connect',target='a'*20,ports=[27015],pin='123456'))
    def test_unicode_and_emoji(self):
        self.relay.request(dict(id=2,action='text',text='中文🙂abc'))
        self.assertEqual(self.device.sock.frames[-1]['text'],'中文🙂abc')
        self.assertEqual(self.device.sock.frames[-1]['document'],'document-a')
    def test_target_is_not_reselected(self):
        self.relay.request(dict(id=2,action='status',target='b'*20))
        self.assertEqual(self.targets,['a'*20])
    def test_duplicate_sequence(self):
        with self.assertRaises(KeyboardError): self.relay.request(dict(id=1,action='text',text='x'))
        self.assertEqual(len(self.device.sock.frames),1)
    def test_control_characters_not_text(self):
        for text in ['\n','\t','a\x00b','\b','\x7f']:
            with self.assertRaises(KeyboardError): self.relay.request(dict(id=self.relay.last_id+1,action='text',text=text))
        self.assertEqual(len(self.device.sock.frames),1)
    def test_emoji_utf16_limit(self):
        with self.assertRaises(KeyboardError): self.relay.request(dict(id=2,action='text',text='🙂'*2049))
    def test_document_rejected_without_retry(self):
        self.device.sock.reject='document_changed'
        with self.assertRaises(KeyboardError): self.relay.request(dict(id=2,action='text',text='x'))
        self.assertEqual(len(self.device.sock.frames),2)
    def test_visual_receipt_is_not_invented(self):
        self.device.sock.bad_receipt=True
        with self.assertRaises(KeyboardError): self.relay.request(dict(id=2,action='text',text='x'))
    def test_focus_and_health_do_not_input(self):
        self.relay.request(dict(id=2,action='focus')); self.relay.request(dict(id=3,action='status'))
        self.assertEqual([f['action'] for f in self.device.sock.frames],['hello','focus','status'])
    def test_only_explicit_return(self):
        self.relay.request(dict(id=2,action='delete')); self.relay.request(dict(id=3,action='return'))
        self.assertEqual(self.device.sock.frames[-1]['action'],'return')
    def test_close_does_not_send(self):
        self.relay.close(); self.assertTrue(self.device.closed); self.assertEqual(len(self.device.sock.frames),1)


class ProjectTests(unittest.TestCase):
    def test_prepared_extension(self):
        path=build.prepare()
        project=plistlib.loads((path/'project.pbxproj').read_bytes())
        types=[v.get('productType') for v in project['objects'].values()]
        self.assertIn('com.apple.product-type.app-extension',types)
        info=plistlib.loads((ROOT/'build/Keyboard.plist').read_bytes())
        self.assertEqual(info['NSExtension']['NSExtensionPointIdentifier'],'com.apple.keyboard-service')
        self.assertTrue(info['NSExtension']['NSExtensionAttributes']['RequestsOpenAccess'])
        self.assertEqual(info['CFBundleShortVersionString'],'1.0.1')
        self.assertEqual(info['CFBundleVersion'],'2')
        references=[v.get('path') for v in project['objects'].values() if v.get('isa')=='PBXFileReference']
        self.assertIn('../Keyboard/KeyboardLoopbackListener.swift', references)
    def test_host_and_extension_documents(self):
        source=(ROOT/'Keyboard/KeyboardViewController.swift').read_text(encoding='utf-8')
        self.assertIn('documentIdentifier',source)
        self.assertNotIn('documentContextBeforeInput',source)
        self.assertNotIn('documentContextAfterInput',source)
        self.assertNotIn('UIPasteboard',source)


if __name__=='__main__': unittest.main()
