#!/usr/bin/env python3
"""Behavioral checks for the fail-closed observer orchestration."""
import ast
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest


LIVE = Path(__file__).with_name("live.py")
MAC_SCREEN = Path(__file__).resolve().parents[3] / "Packages/macOS/CmuxNext/Sources/CmuxNextMacScreen"


def produced_transports():
    """The `transport` values the production pane emits, read from the Swift producer:
    `MacScreenDebug.row` emits `session.transportCarrier`, which `MacScreenSession` sets."""
    debug = (MAC_SCREEN / "MacScreenDebug.swift").read_text()
    session = (MAC_SCREEN / "MacScreenSession.swift").read_text()
    if not re.search(r'row\["transport"\]\s*=\s*session\.transportCarrier\b', debug):
        return set()
    return set(re.findall(r'\btransportCarrier\s*=\s*"([^"]+)"', session))


def accepted_transports():
    tree = ast.parse(LIVE.read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "VALID_TRANSPORTS" for t in node.targets):
            return set(ast.literal_eval(node.value.args[0]))
    return set()


class ObserverRigTests(unittest.TestCase):
    def run_rig(self, *, receipt=None, trigger="OK workspace", motion="/bin/echo", transport=None):
        with tempfile.TemporaryDirectory(prefix="mac-screen-rig-test-") as tmp:
            root = Path(tmp)
            fake_ssh = root / "ssh"
            commands = root / "commands.log"
            state = root / "state.json"
            state.write_text(json.dumps({"connected": False}))
            receipt = receipt or {
                "schema": "cmux.presented-marker-series/2", "complete": True,
                "host_identity_verified": True, "nonce_observed": True,
                "expected_nonce": "00112233445566778899aabbccddeeff", "pid": 7, "window": 42,
                "window_geometry_points": [0, 0, 100, 100], "first_changed_marker_ms": 2.0,
            }
            fake_ssh.write_text("""#!/usr/bin/env python3
import json, os, pathlib, shlex, sys
cmd = sys.argv[-1]
pathlib.Path(os.environ['COMMANDS']).open('a').write(cmd + '\\n')
state_path = pathlib.Path(os.environ['STATE'])
state = json.loads(state_path.read_text())
if 'printf %s "$HOME"' in cmd:
    print('/home/test'); raise SystemExit
if 'mktemp -d' in cmd:
    print('/home/test/rd-hub-rig/run-123'); raise SystemExit
if 'touch ' in cmd and 'printf READY' in cmd:
    print('READY'); raise SystemExit
if 'test -s ' in cmd and 'printf READY' in cmd:
    print('READY'); raise SystemExit
if 'new-workspace' in cmd:
    print(os.environ.get('TRIGGER', 'OK workspace')); raise SystemExit
if 'python3 ~/rd-hub-rig/mini.py' in cmd:
    bits = shlex.split(cmd)
    method = bits[bits.index('rpc') + 1]
    params = json.loads(bits[bits.index('rpc') + 2])
    if method == 'debug.device_hub':
        if params.get('action') == 'connect':
            state['connected'] = True; state_path.write_text(json.dumps(state)); print('{}')
        elif params.get('action') == 'state':
            print(json.dumps({'signed_in': True, 'this_device': 'host', 'connection': 'connected', 'pending_requests': []}))
        else: print('{"ok":true}')
    elif method == 'debug.mac_screen':
        if params.get('action') == 'state':
            if not state.get('connected'): print('{"share":{"screen_recording":true},"tabs":[]}')
            else: print(json.dumps({'share': {'screen_recording': True}, 'tabs': [{
                'tab':'tab-1','window_attestation':True,'window_pid':7,'window_id':42,
                'window_frame_points':{'x':0,'y':0,'width':100,'height':100},
                'content_rect_points':{'x':0,'y':0,'width':100,'height':100},
                'primary_screen_frame_points':{'x':0,'y':0,'width':100,'height':100},
                'window_on_primary_display':True,'geometry_origin':'bottom-left',
                'host_device':'host','hub_session':'session','session_scope':'full',
                'phase':'connected','has_frame':True,'path':'Direct',
                **json.loads(os.environ['PANE_TRANSPORT'])}]}))
        else: print('{"ok":true}')
    else: print('{}')
    raise SystemExit
if 'OBSERVER_READY' in cmd:
    print('OBSERVER_READY', flush=True)
    print(os.environ['RECEIPT'], flush=True)
    raise SystemExit
raise SystemExit
""")
            fake_ssh.chmod(0o755)
            readiness = root / "readiness.json"
            readiness.write_text(json.dumps({"ready": True, "nonce": "00112233445566778899aabbccddeeff",
                                              # The rig requires a nonce issued during its launch window.
                                              "issued_unix_ms": time.time_ns() // 1_000_000 + 500,
                                              "marker_origin": "1,1", "cell_size": 8}))
            out = root / "out"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "COMMANDS": str(commands),
                   "STATE": str(state), "RECEIPT": json.dumps(receipt), "TRIGGER": trigger,
                   # The pane row carries what the Swift producer emits, never an invented carrier.
                   "PANE_TRANSPORT": json.dumps({} if transport is False else
                                                {"transport": transport or sorted(produced_transports())[0]})}
            argv = ["python3", str(LIVE), "--tag", "test", "--host", "host", "--viewer", "viewer",
                    "--out", str(out), "--source-readiness", str(readiness), "--seconds", "0"]
            if motion:
                argv.extend(["--motion", motion])
            proc = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=20)
            return proc, json.loads((out / "result.json").read_text()), commands.read_text()

    def test_start_signal_and_owned_source_cleanup(self):
        proc, result, commands = self.run_rig()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(result["comparison_ready"])
        self.assertIn("touch", commands)
        self.assertIn("--start-file", commands)
        self.assertIn("CMUX_SOURCE_NONCE=00112233445566778899aabbccddeeff", commands)
        self.assertIn("--command 'sh -c", commands)
        self.assertIn("kill", commands)

    def test_producer_emits_a_transport_the_rig_accepts(self):
        produced = produced_transports()
        self.assertTrue(produced, "MacScreenDebug.row must emit session.transportCarrier as `transport`")
        self.assertLessEqual(produced, accepted_transports())

    def test_pane_without_transport_stays_unready(self):
        # A row with only the diagnostic `path` (no carrier) never passes the attestation.
        proc, result, commands = self.run_rig(transport=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(result["comparison_ready"])
        self.assertNotIn("OBSERVER_READY", commands)

    def test_bad_geometry_stays_unready(self):
        receipt = {"schema": "cmux.presented-marker-series/2", "complete": True,
                   "host_identity_verified": True, "nonce_observed": True,
                   "expected_nonce": "00112233445566778899aabbccddeeff", "pid": 7, "window": 42,
                   "window_geometry_points": ["bad", 0, 100, 100], "first_changed_marker_ms": 2.0}
        proc, result, _ = self.run_rig(receipt=receipt)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(result["comparison_ready"])

    def test_wrong_nonce_and_window_stay_unready(self):
        for overrides in ({"expected_nonce": "f" * 32}, {"pid": 8}, {"window": 99}):
            receipt = {"schema": "cmux.presented-marker-series/2", "complete": True,
                       "host_identity_verified": True, "nonce_observed": True,
                       "expected_nonce": "00112233445566778899aabbccddeeff", "pid": 7, "window": 42,
                       "window_geometry_points": [0, 0, 100, 100], "first_changed_marker_ms": 2.0}
            receipt.update(overrides)
            proc, result, _ = self.run_rig(receipt=receipt)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertFalse(result["comparison_ready"])

    def test_missing_source_trigger_fails_closed(self):
        proc, result, commands = self.run_rig(motion=None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(result["comparison_ready"])
        self.assertNotIn("OBSERVER_READY", commands)

    def test_source_start_failure_cleans_up(self):
        proc, result, commands = self.run_rig(trigger="source failed")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(result["comparison_ready"])
        self.assertIn("kill", commands)


if __name__ == "__main__":
    unittest.main()
