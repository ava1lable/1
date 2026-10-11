"""Exact-target USB keyboard relay. No WDA, clipboard, discovery fallback or replay."""
import hashlib
import json
import sys

MAX = 65536


class KeyboardError(Exception):
    def __init__(self, code): self.code = code


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
        if not reply['ok']: raise KeyboardError(reply.get('code', 'keyboard_rejected'))
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
            number = 0
            try:
                if len(line) > MAX or not line.endswith(b'\n'): raise KeyboardError('frame_too_large')
                frame = json.loads(line)
                if type(frame) is not dict: raise KeyboardError('invalid_frame')
                number = frame.get('id', 0)
                response = relay.request(frame)
            except Exception as error:
                code = error.code if isinstance(error, KeyboardError) else 'transport_failed'
                response = dict(id=number, ok=False, code=code)
                relay.close()  # Unknown writes may have succeeded: never retry.
            sys.stdout.write(json.dumps(response, separators=(',', ':')) + '\n'); sys.stdout.flush()
    finally: relay.close()


if __name__ == '__main__': main()
