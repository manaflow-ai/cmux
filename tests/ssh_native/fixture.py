#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["asyncssh==2.24.0"]
# ///
"""Disposable AsyncSSH loopback fixture for the libssh probe.

The fixture owns a temporary directory and never touches user SSH files. It
starts an AsyncSSH server on 127.0.0.1:0, invokes the compiled harness for
fixed protocol cases, and writes result.json. Passwords and private keys are
only passed by mode-specific file paths, never command-line values.
"""
from __future__ import annotations
import argparse, asyncio, base64, json, os, pathlib, shutil, subprocess, sys, tempfile
import asyncssh

USER = "fixture"
PASSWORD = "correct-password"
KBD_ANSWERS = ["first-factor", "second-factor"]

class FixtureServer(asyncssh.SSHServer):
    def __init__(self, ed_pub: str, rsa_pub: str):
        self.ed_pub = ed_pub
        self.rsa_pub = rsa_pub
        self.kbd_rounds = {}

    def connection_requested(self, dest_host, dest_port, orig_host, orig_port):
        return False

    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == USER and password == PASSWORD

    def kbdint_auth_supported(self):
        return True

    def get_kbdint_challenge(self, username, lang, submethods):
        if username != USER:
            return False
        if username not in self.kbd_rounds:
            self.kbd_rounds[username] = 0
        return ("cmux fixture", "two rounds", "", [("First factor" if self.kbd_rounds[username] == 0 else "Second factor", False)])

    def validate_kbdint_response(self, username, responses):
        if username != USER or len(responses) != 1:
            return False
        round_no = self.kbd_rounds.get(username, 0)
        expected = KBD_ANSWERS[round_no] if round_no < len(KBD_ANSWERS) else None
        if responses[0] != expected:
            return False
        self.kbd_rounds[username] = round_no + 1
        if round_no == 0:
            return ("cmux fixture", "two rounds", "", [("Second factor", False)])
        return True

    def public_key_auth_supported(self):
        return True

    def validate_public_key(self, username, key):
        if username != USER:
            return False
        fp = key.get_fingerprint("sha256")
        return fp in {self.ed_pub, self.rsa_pub}

async def fixture_process(proc):
    command = proc.command
    if command and command.startswith("cmux-tui relay"):
        async for line in proc.stdin:
            try:
                request = json.loads(line)
                request_id = request.get("id")
                name = request.get("cmd")
                if name == "identify":
                    response = {"id": request_id, "ok": True, "data": {"app": "cmux-tui", "protocol": 12}}
                elif name == "set-client-info":
                    response = {"id": request_id, "ok": True, "data": {}}
                elif name == "list-workspaces":
                    response = {"id": request_id, "ok": True, "data": {"workspaces": [{"id": "fixture-workspace"}]}}
                elif name == "attach-surface":
                    response = {"id": request_id, "ok": True, "data": {"lease": "fixture-lease"}}
                else:
                    response = {"id": request_id, "ok": False, "error": "unknown command"}
                proc.stdout.write(json.dumps(response) + "\n")
            except Exception:
                proc.stdout.write("{not-json}\n")
        return
    if command == "printf cmux-fixed-output":
        proc.stdout.write("cmux-fixed-output\n")
        proc.exit(0)
        return
    if command == "printf cmux-pty-output":
        proc.stdout.write("cmux-pty-output\n")
        proc.exit(0)
        return
    if command is None:
        def on_resize(width, height, pixwidth, pixheight):
            proc.stdout.write(f"RESIZED:{width}x{height}\n")
        proc.terminal_size_changed = on_resize
        proc.stdout.write("READY\n")
        async for data in proc.stdin:
            if data == "ping\n":
                proc.stdout.write("PONG\n")
            elif data == "exit\n":
                proc.exit(0)
                return
        return
    proc.exit(127)

async def run(args):
    root = pathlib.Path(tempfile.mkdtemp(prefix="cmux-ssh-probe-"))
    try:
        keydir = root / "keys"
        keydir.mkdir()
        host_key = keydir / "host_ed25519"
        ed_key = keydir / "user_ed25519"
        rsa_key = keydir / "user_rsa"
        asyncssh.generate_private_key("ssh-ed25519").write_private_key(str(host_key), format_name="openssh")
        asyncssh.generate_private_key("ssh-ed25519").write_private_key(str(ed_key), format_name="openssh")
        subprocess.run(["ssh-keygen", "-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", str(rsa_key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # OpenSSH public keys are accepted by libssh; AsyncSSH returns a line with comment.
        for priv in (ed_key, rsa_key):
            pub = pathlib.Path(str(priv) + ".pub")
            key = asyncssh.read_private_key(str(priv))
            pub.write_text(key.export_public_key().decode())
        edfp = asyncssh.read_private_key(str(ed_key)).get_fingerprint("sha256")
        rsafp = asyncssh.read_private_key(str(rsa_key)).get_fingerprint("sha256")
        hostfp = asyncssh.read_private_key(str(host_key)).get_fingerprint("sha256")
        (root / "username").write_text(USER + "\n")
        (root / "password").write_text(PASSWORD + "\n")
        (root / "fixture.txt").write_text("fixture-sftp\n")
        (root / "password-bad").write_text("incorrect-password\n")
        (root / "kbd-answers").write_text("\n".join(KBD_ANSWERS) + "\n")
        (root / "host-fingerprint").write_text(hostfp.removeprefix("SHA256:") + "\n")
        (root / "host-fingerprint-bad").write_text("A" * 43 + "\n")
        for item in root.rglob("*"):
            if item.is_file(): item.chmod(0o600)
        srv = await asyncssh.create_server(
            lambda: FixtureServer(edfp, rsafp),
            host="127.0.0.1", port=0,
            server_host_keys=[str(host_key)],
            signature_algs=["rsa-sha2-512", "rsa-sha2-256", "ssh-ed25519"],
            process_factory=fixture_process,
            sftp_factory=lambda chan: asyncssh.SFTPServer(chan, chroot=str(root)),
        )
        port = srv.get_addresses()[0][1]
        if args.server_only:
            if not args.server_info:
                raise SystemExit("--server-info is required with --server-only")
            pathlib.Path(args.server_info).write_text(json.dumps({
                "host": "127.0.0.1", "port": port, "username": USER,
                "password": PASSWORD, "hostFingerprint": hostfp,
                "ed25519PrivateKey": base64.b64encode(ed_key.read_bytes()).decode()
            }) + "\n")
            await asyncio.Event().wait()
            return
        env = os.environ.copy()
        env.update({
            "CMUX_FIXTURE_ROOT": str(root),
            "CMUX_FIXTURE_PORT": str(port),
        })
        # Fixture only invokes a local binary path controlled by this experiment.
        if not args.harness: raise SystemExit("--harness is required unless --server-only")
        harness = pathlib.Path(args.harness).resolve()
        modes = [
            ("hostkey-ok", ["--expect-success"]),
            ("hostkey-bad", ["--expect-failure"]),
            ("password-ok", ["--expect-success"]),
            ("password-bad", ["--expect-failure"]),
            ("kbd-ok", ["--expect-success"]),
            ("kbd-bad", ["--expect-failure"]),
            ("key-ed25519", ["--expect-success"]),
            ("key-rsa", ["--expect-success"]),
            ("exec", ["--expect-success"]),
            ("pty-resize", ["--expect-success"]),
            ("sftp", ["--expect-success"]),
        ]
        cases = []
        for mode, expectation in modes:
            proc = await asyncio.create_subprocess_exec(
                str(harness), mode, str(port), str(root), *expectation,
                cwd=str(root), env=env,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), 15)
            except asyncio.TimeoutError:
                proc.kill()
                stdout, stderr = await proc.communicate()
                stderr += b"\nfixture per-case timeout"
            try:
                payload = json.loads(stdout.decode())
            except Exception:
                payload = {"mode": mode, "ok": False, "error": "invalid harness JSON", "stdout": stdout.decode(errors="replace")[:400]}
            payload["exit_code"] = proc.returncode
            if stderr:
                payload["stderr"] = stderr.decode(errors="replace")[:12000]
            cases.append(payload)
        result = {
            "versions": {"asyncssh": asyncssh.__version__, "libssh": args.libssh_version},
            "fixture": {"host": "127.0.0.1", "port": port, "username": USER},
            "cases": cases,
            "notes": [
                "Loopback only; no user SSH config, keys, known_hosts, or network hosts were touched.",
                "Passwords and private keys were fixture files with mode 0600 and are not printed.",
                "Host key pinning compared libssh SHA-256 host-key bytes against AsyncSSH SHA256 fingerprint.",
            ],
        }
        (pathlib.Path(args.output)).write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        if not all(case.get("ok") and case.get("exit_code") == 0 for case in cases):
            raise SystemExit("Native SSH matrix failed")
    finally:
        try:
            srv.close()
            await srv.wait_closed()
        except Exception:
            pass
        shutil.rmtree(root, ignore_errors=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--harness")
    ap.add_argument("--server-only", action="store_true")
    ap.add_argument("--server-info")
    ap.add_argument("--output")
    ap.add_argument("--libssh-version", default="unknown")
    args = ap.parse_args()
    asyncio.run(run(args))

if __name__ == "__main__":
    main()
