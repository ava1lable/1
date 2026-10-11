"""Exact-target USB keyboard relay. No WDA, clipboard, discovery fallback or replay."""
import hashlib
import json
import datetime
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

MAX = 65536
DIAGNOSTIC_REVISION = 'connection-d1'
ACTION_CODES = frozenset(('connect', 'text', 'delete', 'return', 'focus', 'status'))
ERROR_CODES = frozenset(('invalid_target', 'ambiguous_target', 'target_disconnected',
    'frame_too_large', 'keyboard_inactive', 'invalid_reply', 'already_connected',
    'invalid_pin', 'not_connected', 'unsupported_action', 'invalid_text',
    'invalid_sequence', 'invalid_receipt', 'invalid_frame', 'pairing_denied',
    'document_changed', 'keyboard_hidden', 'keyboard_rejected', 'transport_failed'))


def diagnostic(action, outcome, code='', error=None, elapsed=0):
    """Bounded metadata only: never serialize requests, replies or exception messages."""
    try:
        directory = os.environ.get('IPHONE_MIRROR_APP_LOG_DIRECTORY')
        native = os.environ.get('IPHONE_MIRROR_LOG_FILE')
        if directory and Path(directory).is_absolute():
            folder = Path(directory)
        elif native and Path(native).is_absolute():
            folder = Path(native).parent
        else:
            return
        origin = 'protocol' if isinstance(error, KeyboardError) else 'none'
        if isinstance(error, TimeoutError): origin = 'timeout'
        elif isinstance(error, ConnectionResetError): origin = 'connection_reset'
        elif isinstance(error, BrokenPipeError): origin = 'broken_pipe'
        elif isinstance(error, OSError): origin = 'socket_error'
        elif error is not None and not isinstance(error, KeyboardError): origin = 'other'
        entry = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            revision=DIAGNOSTIC_REVISION, pid=os.getpid(),
            action=action if isinstance(action, str) and action in ACTION_CODES else 'unknown',
            outcome=outcome if outcome in ('accepted', 'failed', 'worker_stopped') else 'unknown',
            code=code if isinstance(code, str) and code in ERROR_CODES else ('unknown_error' if code else ''),
            origin=origin, elapsed_ms=max(0, min(60000, int(elapsed * 1000))))
        folder.mkdir(parents=True, exist_ok=True)
        path = folder/'phone-keyboard-events.jsonl'
        if path.exists() and path.stat().st_size > 1_048_576:
            path.replace(folder/'phone-keyboard-events.previous.jsonl')
        with path.open('a', encoding='utf-8') as out:
            out.write(json.dumps(entry, separators=(',', ':')) + '\n')
    except Exception:
        pass  # Diagnostics never change the input or connection result.


class KeyboardError(Exception):
    def __init__(self, code): self.code = code


class RejectedRequest(KeyboardError):
    """A complete phone rejection, before editing, with a synchronized stream."""
    def __init__(self, code, recoverable=False):
        super().__init__(code)
        self.recoverable = recoverable


def target_token(udid):
    return hashlib.sha256(('mirror-wda-workbench-1:' + udid.lower()).encode()).hexdigest()[:20]


def resolve(target, ports):
    import tidevice
    import probe
    from tidevice._proto import ConnectionType
    if not isinstance(target, str) or len(target) != 20:
        raise KeyboardError('invalid_target')
    for port in ports:
        if type(port) is not int or not 0 < port < 65536: continue
        try:
            mux = tidevice.Usbmux(('127.0.0.1', port))
            matches = [d for d in mux.device_list() if d.conn_type == ConnectionType.USB and target_token(d.udid) == target]
        except Exception: continue
        if len(matches) > 1: raise KeyboardError('ambiguous_target')
        if len(matches) == 1:
            return probe.device_class()(matches[0].udid, usbmux=mux)
    raise KeyboardError('target_disconnected')


class Relay:
    def __init__(self, resolver=resolve):
        self.resolver = resolver; self.proxy = self.sock = None
        self.session = self.document = None
        self.buffer = bytearray()
        self.last_id = 0

    def close(self):
        if self.proxy: self.proxy.close()
        self.proxy = self.sock = None
        self.session = self.document = None

    def exchange(self, frame):
        data = json.dumps(frame, ensure_ascii=False, separators=(',', ':')).encode('utf-8') + b'\n'
        if len(data) > MAX: raise KeyboardError('frame_too_large')
        self.sock.sendall(data)
        while b'\n' not in self.buffer:
            part = self.sock.recv(8192)
            if not part: raise KeyboardError('keyboard_inactive')
            self.buffer.extend(part)
            if len(self.buffer) > MAX: raise KeyboardError('frame_too_large')
        line, _, remainder = self.buffer.partition(b'\n'); self.buffer = bytearray(remainder)
        reply = json.loads(line.decode('utf-8'))
        if type(reply) is not dict or reply.get('v') != 1 or reply.get('id') != frame['id'] or type(reply.get('ok')) is not bool:
            raise KeyboardError('invalid_reply')
        if not reply['ok']:
            code = reply.get('code', 'keyboard_rejected')
            recoverable = frame.get('action') in ('text', 'delete', 'return', 'focus') and code in ('document_changed', 'keyboard_hidden')
            raise RejectedRequest(code, recoverable)
        return reply

    def request(self, frame):
        number = frame.get('id')
        if type(number) is not int or number <= self.last_id: raise KeyboardError('invalid_sequence')
        self.last_id = number
        action = frame.get('action')
        if action == 'connect':
            if self.sock: raise KeyboardError('already_connected')
            pin = frame.get('pin')
            if not isinstance(pin, str) or len(pin) != 6 or not pin.isascii() or not pin.isdigit(): raise KeyboardError('invalid_pin')
            device = self.resolver(frame.get('target'), frame.get('ports') or [])
            self.proxy = device.create_inner_connection(9031)
            self.sock = self.proxy.get_socket(); self.sock.settimeout(6)
            reply = self.exchange(dict(v=1, id=number, action='hello', pin=pin))
            self.session, self.document = reply.get('session'), reply.get('document')
            if not isinstance(self.session, str) or not isinstance(self.document, str): raise KeyboardError('invalid_reply')
        else:
            if self.sock is None: raise KeyboardError('not_connected')
            if action not in ('text', 'delete', 'return', 'focus', 'status'): raise KeyboardError('unsupported_action')
            payload = dict(v=1, id=number, action=action, session=self.session, document=self.document)
            if action == 'text':
                text = frame.get('text')
                if not isinstance(text, str) or not text or len(text.encode('utf-16-le')) // 2 > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in text):
                    raise KeyboardError('invalid_text')
                payload['text'] = text
            reply = self.exchange(payload)
            if action == 'focus':
                document = reply.get('document')
                if not isinstance(document, str): raise KeyboardError('invalid_reply')
                self.document = document
            if action in ('text', 'delete', 'return') and reply.get('receipt') != 'proxy_invoked': raise KeyboardError('invalid_receipt')
        return dict(id=number, ok=True)


def main():
    relay = Relay()
    try:
        while True:
            line = sys.stdin.buffer.readline(MAX + 1)
            if not line: break
            number = 0; action = 'unknown'; started = time.monotonic()
            try:
                if len(line) > MAX or not line.endswith(b'\n'): raise KeyboardError('frame_too_large')
                frame = json.loads(line)
                if type(frame) is not dict: raise KeyboardError('invalid_frame')
                number = frame.get('id', 0)
                action = frame.get('action')
                response = relay.request(frame)
                diagnostic(action, 'accepted', elapsed=time.monotonic() - started)
            except Exception as error:
                code = error.code if isinstance(error, KeyboardError) else 'transport_failed'
                response = dict(id=number, ok=False, code=code)
                diagnostic(action, 'failed', code, error, time.monotonic() - started)
                if isinstance(error, RejectedRequest) and error.recoverable:
                    response['recoverable'] = True
                else:
                    relay.close()  # Unknown writes may have succeeded: never retry.
            sys.stdout.write(json.dumps(response, separators=(',', ':')) + '\n'); sys.stdout.flush()
    finally:
        relay.close()
        diagnostic('unknown', 'worker_stopped')


if __name__ == '__main__': main()
