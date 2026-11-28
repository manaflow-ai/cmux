#!/usr/bin/env python3
"""Prove a dedicated NIGHTLY's Accounts connection and repository picker through its UI.

Only official cmux Computer Use drives native sign-in windows. Secrets travel on
MCP stdin; screenshots never include a populated authentication form. The caller
must launch an isolated signed NIGHTLY and supply its verified PID and socket.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import plistlib
import re
import select
import shutil
import struct
import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit

SECRET_NAMES = ("CMUX_GITHUB_TEST_LOGIN", "CMUX_GITHUB_TEST_PASSWORD", "CMUX_GITHUB_TEST_TOTP_SEED")
OMNIBAR = "cmux.browserPopup.omnibar"


class ProbeError(RuntimeError):
    pass


class ComputerUse:
    """Small bounded MCP client; tool refusals are terminal, never retried."""

    def __init__(self):
        executable = shutil.which("cmux")
        if not executable:
            raise ProbeError("Host cmux CLI is unavailable")
        self.executable = executable
        self.starting = True
        self.startup_stderr = b""
        self.stderr_truncated = False
        self.stderr_open = True
        self.process = subprocess.Popen([executable, "computer-use", "mcp"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b""
        self.sequence = 0
        try:
            self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                         "clientInfo": {"name": "cmux-accounts-nightly-probe", "version": "1"}})
            self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            self.process.stdin.flush()
            # Never retain stderr from later calls: Accounts passes sign-in data over MCP.
            self.starting = False
            self.startup_stderr = b""
        except Exception as error:
            self.close()
            retained = self.startup_stderr
            if self.stderr_truncated:
                # The first retained line may begin inside a credential. Drop it entirely.
                retained = retained.partition(b"\n")[2]
            detail = retained.decode("utf-8", errors="replace")
            secrets = set()
            for name, value in os.environ.items():
                if value and (name in SECRET_NAMES or
                              re.search(r"password|secret|token|credential|key", name, re.I)):
                    # Redact individual lines too: truncation can remove a multiline value's prefix.
                    for part in [value, *value.splitlines()]:
                        if part:
                            secrets.add(part)
            if secrets:
                # A login may prefix a password. Match longest first, once, without rewriting markers.
                pattern = "|".join(re.escape(part) for part in sorted(secrets, key=len, reverse=True))
                detail = re.sub(pattern, "[redacted]", detail)
            detail = re.sub(r"(?i)(bearer\s+)\S+", r"\1[redacted]", detail)
            raise ProbeError(f"Computer Use startup failed ({self.executable}, "
                             f"exit={self.process.returncode}): {error}; "
                             f"stderr: {detail.strip() or '(empty)'}") from error

    def read_stderr(self):
        chunk = os.read(self.process.stderr.fileno(), 65536)
        if not chunk:
            self.stderr_open = False
        elif self.starting:
            combined = self.startup_stderr + chunk
            self.stderr_truncated |= len(combined) > 4096
            self.startup_stderr = combined[-4096:]

    def drain_stderr(self):
        # A dead child cannot keep producing. Bound cleanup even if a descendant holds its pipe.
        for _ in range(16):
            if not self.stderr_open or not select.select([self.process.stderr], [], [], 0)[0]:
                break
            self.read_stderr()

    def close(self):
        if self.process.stdin:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()  # Only this client's own child.
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.drain_stderr()
        self.stderr_open = False
        self.process.stderr.close()
        self.process.stdout.close()

    def request(self, method, params):
        self.sequence += 1
        self.process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.sequence,
                                             "method": method, "params": params}) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 60
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") != self.sequence:
                    continue
                if "error" in message:
                    raise ProbeError("Computer Use MCP request failed")
                return message["result"]
            remaining = deadline - time.monotonic()
            streams = [self.process.stdout]
            if self.stderr_open:
                streams.append(self.process.stderr)
            ready = select.select(streams, [], [], max(0, remaining))[0]
            if remaining <= 0 or not ready:
                raise ProbeError("Computer Use response exceeded 60 seconds")
            if self.process.stderr in ready:
                self.read_stderr()
            if self.process.stdout not in ready:
                continue
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise ProbeError("Computer Use transport closed")
            self.buffer += chunk
            if len(self.buffer) > 32 * 1024 * 1024:
                raise ProbeError("Computer Use response exceeded size bound")

    def call(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            # Never serialize returned arguments or form values in a failure artifact.
            raise ProbeError(f"Computer Use {name} refused or failed; inspect Computer Use status")
        body = {}
        for item in result.get("content", []):
            if item.get("type") == "text":
                body = json.loads(item["text"])
                if body.get("error") or body.get("ok") is False:
                    raise ProbeError(f"Computer Use {name} failed")
        return body, result.get("content", [])


def flatten(node, clip=None):
    if isinstance(node, dict):
        frame = node.get("frame")
        bounds = None
        if frame and frame.get("width", 0) > 0 and frame.get("height", 0) > 0:
            bounds = (frame["x"], frame["y"], frame["x"] + frame["width"], frame["y"] + frame["height"])
        visible = bounds is not None and (clip is None or
                  (bounds[0] < clip[2] and bounds[2] > clip[0] and bounds[1] < clip[3] and bounds[3] > clip[1]))
        if "role" in node and "id" in node:
            yield dict(node, _visible=visible)
        if bounds and (clip is None or node.get("role") in {"scroll_area", "window"}):
            clip = bounds if clip is None else (max(clip[0], bounds[0]), max(clip[1], bounds[1]),
                                                min(clip[2], bounds[2]), min(clip[3], bounds[3]))
        for child in node.get("children", []):
            yield from flatten(child, clip)


def one(nodes, names, roles=None):
    """Exact, unambiguous accessible names; never choose the first substring."""
    matches = [n for n in nodes if n.get("_visible", True) and not n.get("disabled") and
               n.get("name", "").strip().casefold() in {x.casefold() for x in names} and
               (roles is None or n.get("role") in roles)]
    if len(matches) > 1:
        raise ProbeError("Ambiguous accessible control: " + "/".join(names))
    return matches[0] if matches else None


def github_url(nodes):
    bars = [n for n in nodes if n.get("identifier") == OMNIBAR]
    if len(bars) != 1:
        return None
    urls = {n.get("value", "") for n in flatten(bars[0]) if n.get("value", "").startswith("https://")}
    if len(urls) != 1:
        return None
    url = urlsplit(urls.pop())
    if url.scheme != "https" or url.hostname != "github.com" or url.port not in (None, 443) or url.username:
        raise ProbeError("Sign-in panel is not at the expected HTTPS GitHub origin")
    return url


def totp(seed):
    raw = re.sub(r"\s", "", seed).upper()
    key = base64.b32decode(raw + "=" * (-len(raw) % 8))
    digest = hmac.new(key, struct.pack(">Q", int(time.time() // 30)), hashlib.sha1).digest()
    offset = digest[-1] & 15
    return f"{(struct.unpack('>I', digest[offset:offset+4])[0] & 0x7fffffff) % 1000000:06d}"


class Probe:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out)
        self.out.mkdir(parents=True, exist_ok=True)
        (self.out / "screenshots").mkdir(exist_ok=True)
        self.steps = []
        self.cu = None
        self.meta = {}
        self.sensitive = set()

    def record(self, name, detail, screenshot=None):
        item = {"step": name, "ok": True, "detail": detail}
        if screenshot:
            item["screenshot"] = screenshot
        self.steps.append(item)
        print("PASS", name, flush=True)

    def windows(self):
        body, _ = self.cu.call("list_windows")
        windows = [w for w in body.get("windows", []) if w.get("pid") == self.args.pid]
        if any(w.get("denied") for w in windows):
            raise ProbeError("Computer Use denied the probe app window")
        return [w for w in windows if w.get("on_screen") and not w.get("minimized")]

    def scoped(self, window):
        if window not in {w["window_id"] for w in self.windows()}:
            raise ProbeError("Target window is no longer owned by the probe PID")

    def nodes(self, window):
        self.scoped(window)
        body, _ = self.cu.call("get_ui_tree", window_id=window, format="json", max_nodes=5000)
        if body.get("truncated"):
            raise ProbeError("Accessibility tree truncated; cannot prove unique controls")
        return list(flatten(body.get("root", {})))

    def wait(self, callback, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = callback()
            if result:
                return result
            time.sleep(0.5)
        raise ProbeError("Timed out waiting for expected UI state")

    def find(self, names, roles=None, window=None):
        matches = []
        for wid in ([window] if window else [w["window_id"] for w in self.windows()]):
            node = one(self.nodes(wid), names, roles)
            if node:
                matches.append((wid, node))
        if len(matches) > 1:
            raise ProbeError("Control appears in more than one probe window")
        return matches[0] if matches else None

    def click(self, target):
        window, node = target
        self.scoped(window)
        self.cu.call("click", window_id=window, element_id=node["id"], observe=False, settle="adaptive")

    def location(self, window):
        nodes = self.nodes(window)
        bars = [n for n in nodes if n.get("identifier") == OMNIBAR]
        if len(bars) != 1:
            return None
        location = github_url(nodes)
        if location:
            return location
        # The native read-only omnibar elides the scheme until focused.
        fields = [n for n in flatten(bars[0]) if n.get("role") == "text_field"]
        if len(fields) != 1:
            return None
        self.click((window, fields[0]))
        return github_url(self.nodes(window))

    def fill(self, window, node, value):
        # Recheck the native browser location immediately before disclosing a secret.
        if not self.location(window):
            raise ProbeError("Cannot verify native GitHub sign-in location")
        current = self.nodes(window)
        if not github_url(current):
            raise ProbeError("GitHub origin changed before secret input")
        fresh = one(current, [node["name"]], {node["role"]})
        if not fresh:
            raise ProbeError("Authentication field changed before input")
        node = fresh
        self.sensitive.add(window)
        self.scoped(window)
        self.cu.call("set_value", window_id=window, element_id=node["id"], value=value, observe=False)

    def screenshot(self, window, name):
        if window in self.sensitive:
            raise ProbeError("Refusing capture of populated authentication form")
        self.scoped(window)
        _, content = self.cu.call("screenshot", window_id=window, force=True)
        images = [c for c in content if c.get("type") == "image"]
        if len(images) != 1:
            raise ProbeError("Window screenshot did not return exactly one image")
        suffix = {"image/png": ".png", "image/jpeg": ".jpg"}.get(images[0].get("mimeType"))
        if not suffix:
            raise ProbeError("Unsupported screenshot format")
        path = self.out / "screenshots" / (name + suffix)
        path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
        return str(path.relative_to(self.out))

    def action(self, action):
        env = dict(os.environ, CMUX_SOCKET_PATH=self.args.socket)
        cli = self.args.cli or str(Path(self.args.app) / "Contents/Resources/bin/cmux")
        result = subprocess.run([cli, "action", "run", action], env=env, capture_output=True, timeout=60)
        if result.returncode:
            raise ProbeError("NIGHTLY action failed: " + action)

    def authenticate(self, window):
        login, password, seed = [os.environ.get(k, "") for k in SECRET_NAMES]
        if not all((login, password, seed)):
            raise ProbeError("Dedicated GitHub test credentials are absent")
        acted = set()
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            if window not in {w["window_id"] for w in self.windows()}:
                return
            nodes = self.nodes(window)
            location = self.location(window)
            if not location:
                raise ProbeError("Native GitHub location is not readable")
            path = location.path
            if "/verified-device" in path:
                raise ProbeError("GitHub requires device verification; no automated bypass")
            if path in acted:
                time.sleep(0.5)
                continue
            field_roles = {"text_field", "secure_text_field", "text_entry"}
            def control(names, roles=None):
                node = one(self.nodes(window), names, roles)
                if not node:
                    raise ProbeError("Missing GitHub control: " + "/".join(names))
                return node
            def click(names, roles=None):
                self.click((window, control(names, roles)))
            if path.rstrip("/") == "/login":
                self.fill(window, control(["Username or email address"], field_roles), login)
                self.fill(window, control(["Password"], field_roles), password)
                click(["Sign in"], {"button"})
            elif "/sessions/two-factor" in path:
                self.fill(window, control(["Authentication code", "Verification code"], field_roles), totp(seed))
                click(["Verify"], {"button"})
            elif "/sudo" in path:
                self.fill(window, control(["Password", "Confirm your password"], field_roles), password)
                click(["Confirm", "Confirm password"], {"button"})
            elif path == "/login/oauth/authorize":
                click(["Authorize cmux", "Authorize cmux Cloud"], {"button"})
            elif path.endswith("/installations/new"):
                click([self.args.org], {"button", "link"})
            elif path.endswith("/installations/new/permissions"):
                only = control(["Only select repositories"], {"radio_button", "radio"})
                if not only.get("checked"):
                    self.click((window, only))
                picker = self.wait(lambda: self.find(["Select repositories"], window=window))
                self.click(picker)
                target = self.wait(lambda: self.find([f"{self.args.org}/{self.args.repo}"], {"check_box", "checkbox"}, window))
                if not target[1].get("checked"):
                    self.click(target)
                selected = self.nodes(window)
                restricted = one(selected, ["Only select repositories"], {"radio_button", "radio"})
                if not restricted or not restricted.get("checked"):
                    raise ProbeError("Only-select-repositories grant was not confirmed")
                checks = [n for n in selected if n.get("role") in {"check_box", "checkbox"} and n.get("checked")]
                if len(checks) != 1 or checks[0].get("name", "").strip() != f"{self.args.org}/{self.args.repo}":
                    raise ProbeError("Repository grant is not limited to the expected repository")
                click(["Install"], {"button"})
            else:
                time.sleep(0.5)
                continue
            acted.add(path)
        raise ProbeError("GitHub sign-in did not complete within 240 seconds")

    def run(self):
        with open(Path(self.args.app) / "Contents/Info.plist", "rb") as source:
            self.meta = plistlib.load(source)
        self.cu = ComputerUse()
        self.action("openSettings")
        accounts = self.wait(lambda: self.find(["Accounts"], {"button", "row", "tab", "tab_button", "radio"}))
        self.click(accounts)
        connect = self.wait(lambda: self.find(["Connect GitHub"], {"button"}))
        self.record("Connect GitHub visible", "Fresh connection control; existing connections are never reset",
                    self.screenshot(connect[0], "accounts"))
        before = {w["window_id"] for w in self.windows()}
        self.click(connect)
        def auth_window():
            found = [w["window_id"] for w in self.windows()
                     if w["window_id"] not in before and self.location(w["window_id"])]
            if len(found) > 1:
                raise ProbeError("Multiple GitHub sign-in panels")
            return found[0] if found else None
        window = self.wait(auth_window, 60)
        self.record("GitHub native sign-in handoff", "New PID-scoped panel at verified GitHub HTTPS origin",
                    self.screenshot(window, "github-sign-in"))
        self.authenticate(window)
        connected = self.wait(lambda: self.find(["Connected"], {"text"}, window=connect[0]), 60)
        self.record("Accounts connected", "Connected state read from Accounts after sign-in panel closes",
                    self.screenshot(connected[0], "connected"))
        self.action("palette.newAgentChat")
        for name in ("Folder", "Add project…", "GitHub repository"):
            self.click(self.wait(lambda: self.find([name], {"button", "popup_button", "menu_item", "option", "row", "list_item"})))
        repository = f"{self.args.org}/{self.args.repo}"
        target = self.wait(lambda: self.find([repository, repository + " · Private"], {"button", "option", "row", "list_item"}), 60)
        self.record("Repository list visible", "Exact repository row in GitHub picker: " + repository,
                    self.screenshot(target[0], "repository-list"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "socket", "out"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--org", default="cmux-cloud-test-org")
    parser.add_argument("--repo", default="pr-target")
    parser.add_argument("--cli")
    args = parser.parse_args(argv)
    probe = Probe(args)
    status = 1
    try:
        probe.run()
        status = 0
    except Exception as error:
        detail = str(error) if isinstance(error, ProbeError) else type(error).__name__
        for name in SECRET_NAMES:
            value = os.environ.get(name)
            if value:
                detail = detail.replace(value, "[redacted]")
        probe.steps.append({"step": "probe", "ok": False, "detail": detail[:500]})
    finally:
        if probe.cu:
            try:
                probe.cu.close()
            except Exception:
                status = 1
                probe.steps.append({"step": "computer-use cleanup", "ok": False,
                                    "detail": "Owned MCP client did not stop cleanly"})
        result = {"ok": status == 0, "app": {"path": args.app, "pid": args.pid,
                  "version": probe.meta.get("CFBundleShortVersionString"), "commit": probe.meta.get("CMUXCommit")},
                  "repo": f"{args.org}/{args.repo}", "steps": probe.steps,
                  "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        (probe.out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        (probe.out / "summary.md").write_text("# Accounts NIGHTLY probe\n\n" + "\n".join(
            f"- {'PASS' if item['ok'] else 'FAIL'} **{item['step']}**: {item['detail']}" for item in probe.steps) + "\n")
        print("ACCOUNTS_NIGHTLY_PROBE " + json.dumps(result, separators=(",", ":")), flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
