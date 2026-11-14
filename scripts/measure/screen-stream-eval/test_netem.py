"""Real socket checks for both relay directions and native Hello negotiation."""
import importlib.util
import json
import os
import socket
import struct
import subprocess
import threading
import time
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('relay', Path(__file__).with_name('netem.py'))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(('127.0.0.1', 0))
    s.settimeout(0.3)
    return s


class RelayTests(unittest.TestCase):
    def exercise(self, loss):
        with udp() as host, udp() as viewer, udp() as middle:
            middle.settimeout(None)
            shaper = relay.DelayedUDP(middle, 0.025, loss, 123, host.getsockname())
            thread = threading.Thread(target=shaper.run, daemon=True)
            thread.start()
            try:
                viewer.sendto(b'', middle.getsockname())
                # Feedback follows registration on the same datagram socket.
                started = time.monotonic()
                viewer.sendto(b'feedback', middle.getsockname())
                if loss == 0:
                    payload, source = host.recvfrom(1024)
                    self.assertEqual(payload, b'feedback')
                    self.assertEqual(source, middle.getsockname())
                    self.assertGreaterEqual(time.monotonic() - started, 0.020)
                else:
                    with self.assertRaises(socket.timeout):
                        host.recvfrom(1024)
                started = time.monotonic()
                host.sendto(b'video', middle.getsockname())
                if loss == 0:
                    payload, source = viewer.recvfrom(1024)
                    self.assertEqual(payload, b'video')
                    self.assertEqual(source, middle.getsockname())
                    self.assertGreaterEqual(time.monotonic() - started, 0.020)
                else:
                    with self.assertRaises(socket.timeout):
                        viewer.recvfrom(1024)
                self.assertEqual(shaper.probes, 1)
                for direction in ('upstream', 'downstream'):
                    self.assertEqual(shaper.counts[direction]['received'], 1)
                    self.assertEqual(shaper.counts[direction]['dropped'], int(loss == 1))
            finally:
                shaper.close()

    def test_both_directions_are_delayed(self):
        self.exercise(0)

    def test_both_directions_can_be_dropped(self):
        self.exercise(1)

    @unittest.skipUnless(os.environ.get('CMUX_RD_EVAL_BIN'), 'native binary supplied by fleet build')
    def test_native_hello_advertises_relay_and_registers_viewer(self):
        with socket.socket() as tcp:
            tcp.bind(('127.0.0.1', 0))
            tcp.listen(1)
            tcp.settimeout(10)
            addr = tcp.getsockname()
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as datagrams:
                datagrams.bind(addr)
                datagrams.settimeout(10)
                process = subprocess.Popen([os.environ['CMUX_RD_EVAL_BIN'], 'bench', '--addr',
                    f'{addr[0]}:{addr[1]}', '--eval-netem-relay', '1', '--input', 'none'],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    with tcp.accept()[0] as conn:
                        conn.settimeout(10)
                        def receive(n):
                            out = b''
                            while len(out) < n:
                                chunk = conn.recv(n - len(out))
                                if not chunk:
                                    self.fail('bench closed before Hello')
                                out += chunk
                            return out
                        header = receive(5)
                        self.assertEqual(header[0], 1)
                        hello = json.loads(receive(struct.unpack('<I', header[1:])[0]))
                        self.assertEqual(hello['udp_port'], addr[1])
                        probe, viewer = datagrams.recvfrom(1024)
                        self.assertEqual(probe, b'')
                        self.assertNotEqual(viewer[1], addr[1])
                finally:
                    process.terminate()  # Exact owned process, never a name lookup.
                    process.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main()
