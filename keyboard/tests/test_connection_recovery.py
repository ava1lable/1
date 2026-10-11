"""Exercise the real worker main loop: acknowledged rejection vs uncertain write."""
from io import BytesIO, StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import json
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keyboard_worker as worker


class Transport:
    def __init__(self, rejection):
        self.rejection = rejection; self.actions = []; self.closed = False; self.response = b''
    def create_inner_connection(self, port):
        assert port == 9031
        return self
    def get_socket(self): return self
    def settimeout(self, timeout): pass
    def close(self): self.closed = True
    def sendall(self, data):
        frame = json.loads(data); self.actions.append(frame['action'])
        response = dict(v=1, id=frame['id'], ok=True, session='synthetic-session', document='synthetic-document', receipt='proxy_invoked')
        if frame['action'] == 'text' and self.rejection:
            code = self.rejection; self.rejection = None
            if code == 'timeout': raise TimeoutError('uncertain write')
            response.update(ok=False, code=code)
        self.response = json.dumps(response).encode() + b'\n'
    def recv(self, count):
        data = self.response[:count]; self.response = self.response[count:]; return data


class RecoveryTests(unittest.TestCase):
    def run_worker(self, rejection):
        transport = Transport(rejection)
        relay = worker.Relay(lambda *_: transport)
        frames = [dict(id=1, action='connect', pin='123456'), dict(id=2, action='focus'),
                  dict(id=3, action='text', text='first'), dict(id=4, action='status'),
                  dict(id=5, action='focus'), dict(id=6, action='text', text='second')]
        incoming = BytesIO(b''.join(json.dumps(f).encode()+b'\n' for f in frames))
        outgoing = StringIO()
        with patch.object(worker, 'Relay', return_value=relay), patch.object(worker.sys, 'stdin', SimpleNamespace(buffer=incoming)), \
             patch.object(worker.sys, 'stdout', outgoing), patch.object(worker, 'diagnostic'):
            worker.main()
        return transport, [json.loads(l) for l in outgoing.getvalue().splitlines()]
    def test_document_rejection_keeps_connection_without_replay(self):
        transport, replies = self.run_worker('document_changed')
        self.assertTrue(replies[2]['recoverable'])
        self.assertTrue(all(replies[i]['ok'] for i in (0,1,3,4,5)))
        self.assertEqual(transport.actions, ['hello','focus','text','status','focus','text'])
    def test_hidden_keyboard_does_not_destroy_pairing(self):
        transport, replies = self.run_worker('keyboard_hidden')
        self.assertTrue(replies[2]['recoverable'])
        self.assertTrue(replies[-1]['ok'])
        self.assertEqual(transport.actions.count('hello'),1)
    def test_timeout_does_not_retry_uncertain_text(self):
        transport, replies = self.run_worker('timeout')
        self.assertFalse(replies[2]['ok'])
        self.assertNotIn('recoverable', replies[2])
        self.assertEqual(transport.actions,['hello','focus','text'])
        self.assertTrue(transport.closed)
        self.assertFalse(replies[-1]['ok'])
    def test_invalid_session_is_fatal(self):
        transport, replies = self.run_worker('keyboard_inactive')
        self.assertNotIn('recoverable',replies[2])
        self.assertEqual(transport.actions,['hello','focus','text'])
    def test_unknown_rejection_is_fatal(self):
        transport, replies = self.run_worker('unrecognized')
        self.assertNotIn('recoverable',replies[2])
        self.assertEqual(transport.actions,['hello','focus','text'])


if __name__ == '__main__': unittest.main()
