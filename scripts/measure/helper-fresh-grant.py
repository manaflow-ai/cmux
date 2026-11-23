#!/usr/bin/env python3
"""helper-fresh-grant.sh's driver (cmux#49813): a grant made while cmux runs is used with no restart.

helper-fresh-grant.py --app APP --out DIR --work DIR --account-home DIR [--viewer CMUX_RD] [--marker BIN]
                      [--disclaim BIN] [--share 0|1]

Only on a SIP-off CI fixture (helper-fresh-grant.sh checks): it removes and writes the TCC rows of APP's Screen
Sharing helper. Parts, each with its verdict in DIR/report.json and an HFG line:

  a  rows removed; the app started (its daemon with it); `cmux computer-use status` reads screen_capture missing
     and a screenshot fails; the rows written; status must read granted and a screenshot succeed within
     GRANT_DEADLINE seconds, while the app and its daemon stay the same processes. The worker's pid before and
     after says whether the worker restarted (it should: macOS keeps a running process's old denial).
  b  list_apps, then TextEdit: list_windows, screenshot, click, type_text, and the UI tree reads the typed text.
  c  the helper's own share host (`cmux-screen-sharing host`, its own responsible process) streams to a
     `cmux-rd bench` viewer on this Mac, which must decode frames (loopback-bench.sh's shape, with the marker).

Exit 0 when every part run passed, 1 when one failed, 3 when it could not run.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import secrets
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

SERVICES = ("kTCCServiceAccessibility", "kTCCServicePostEvent", "kTCCServiceScreenCapture")
SYSTEM_TCC = "/Library/Application Support/com.apple.TCC/TCC.db"
GRANT_DEADLINE = 20.0
TEXTEDIT = "com.apple.TextEdit"
TYPED = "typed by cmux computer use"


def now() -> float:
    return time.monotonic()


def line(text: str) -> None:
    print(f"HFG {time.strftime('%H:%M:%S', time.gmtime())} {text}", flush=True)


def sh(args: list[str], *, timeout: float = 60, input_text: str | None = None, env: dict | None = None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, input=input_text, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "timeout"
    except OSError as e:
        return 127, "", str(e)


class Run:
    def __init__(self, a: argparse.Namespace):
        self.app = Path(a.app)
        self.out = Path(a.out)
        self.work = Path(a.work)
        self.account_home = Path(a.account_home)
        self.viewer = a.viewer
        self.marker = a.marker
        self.disclaim = a.disclaim
        self.share = a.share == "1"
        self.report: dict = {"schema": "cmux.helper-fresh-grant/1", "app": str(self.app), "parts": {}}
        self.started: list[subprocess.Popen] = []
        self.started_pids: list[int] = []
        self.home = self.work / "home"
        for sub in ("Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"):
            (self.home / sub).mkdir(parents=True, exist_ok=True)
        (self.work / "t").mkdir(exist_ok=True)
        self.env = {
            "HOME": str(self.home),
            "CFFIXED_USER_HOME": str(self.home),
            "TMPDIR": str(self.work / "t") + "/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": os.environ.get("USER") or os.environ.get("LOGNAME") or "",
            "LANG": "en_US.UTF-8",
        }
        helpers = sorted((self.app / "Contents/Library").glob("* Screen Sharing.app"))
        if not helpers:
            raise SystemExit(self.cannot(f"{self.app.name} carries no Screen Sharing helper in Contents/Library"))
        self.helper = helpers[0]
        info = plistlib.loads((self.helper / "Contents/Info.plist").read_bytes())
        self.helper_id = info["CFBundleIdentifier"]
        app_info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.app_exe = self.app / "Contents/MacOS" / app_info["CFBundleExecutable"]
        self.cli = next((p for p in (self.app / "Contents/Resources/bin/cmux", self.app / "Contents/Resources/bin/cmux-tui")
                         if p.is_file()), None)
        if self.cli is None:
            raise SystemExit(self.cannot("the app has no Contents/Resources/bin/cmux"))
        self.session = ""
        self.report.update(helper=str(self.helper), helper_id=self.helper_id, cli=str(self.cli))
        line(f"helper {self.helper.name} id {self.helper_id}")
        code, o, e = sh(["codesign", "-dv", str(self.helper)])
        sig = re.findall(r"^(Authority|TeamIdentifier|Signature)=?(.*)$", o + e, re.M)
        self.report["helper_signature"] = [f"{k}{(' ' + v) if v else ''}" for k, v in sig]
        line("helper signature: " + "; ".join(self.report["helper_signature"]))

    def cannot(self, why: str) -> int:
        line(f"cannot run: {why}")
        self.report["cannot_run"] = why
        self.save()
        return 3

    def save(self) -> None:
        (self.out / "report.json").write_text(json.dumps(self.report, indent=2) + "\n")

    # ---- TCC -------------------------------------------------------------------------------------------------
    def user_db(self) -> str:
        return str(self.account_home / "Library/Application Support/com.apple.TCC/TCC.db")

    def revoke(self) -> dict:
        res = {}
        for svc in ("Accessibility", "PostEvent", "ScreenCapture"):
            res[f"tccutil {svc}"] = sh(["tccutil", "reset", svc, self.helper_id])[0]
        sql = f"DELETE FROM access WHERE client='{self.helper_id}';"
        res["user db"] = sh(["sqlite3", self.user_db(), sql])[0]
        res["system db"] = sh(["sudo", "-n", "sqlite3", SYSTEM_TCC, sql])[0]
        return res

    def rows(self) -> dict:
        q = f"SELECT service, auth_value FROM access WHERE client='{self.helper_id}';"
        return {"user": sh(["sqlite3", self.user_db(), q])[1].split(), "system": sh(["sudo", "-n", "sqlite3", SYSTEM_TCC, q])[1].split()}

    def grant(self) -> dict:
        code, o, e = sh(["codesign", "-d", "-r-", str(self.helper)])
        m = re.search(r"designated => (.+)", o + e)
        if not m:
            raise RuntimeError(f"no designated requirement: {(o + e).strip()[-200:]}")
        blob = self.work / "helper.csreq"
        code, _, err = sh(["csreq", "-r-", "-b", str(blob)], input_text=m.group(1).strip())
        if code != 0 or not blob.exists():
            raise RuntimeError(f"csreq exit {code}: {err.strip()[-200:]}")
        hexed = blob.read_bytes().hex()
        rows = ",".join(f"('{svc}','{self.helper_id}',0,2,4,1,X'{hexed}',NULL,0,'UNUSED',NULL,0,"
                        "CAST(strftime('%s','now') AS INTEGER))" for svc in SERVICES)
        sql = ("INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, "
               "csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, "
               f"indirect_object_code_identity, flags, last_modified) VALUES {rows};")
        return {"designated": m.group(1).strip(), "user db": sh(["sqlite3", self.user_db(), sql])[0],
                "system db": sh(["sudo", "-n", "sqlite3", SYSTEM_TCC, sql])[0]}

    # ---- processes -------------------------------------------------------------------------------------------
    def procs(self) -> list[tuple[int, str]]:
        code, o, _ = sh(["ps", "-axww", "-o", "pid=,args="], timeout=20)
        out = []
        for raw in o.splitlines():
            raw = raw.strip()
            pid, _, args = raw.partition(" ")
            if pid.isdigit():
                out.append((int(pid), args.strip()))
        return out

    def daemon(self) -> tuple[int, str] | None:
        for pid, args in self.procs():
            m = re.search(r" --session (cmux-app\S*)", args)
            if m and " --headless" in args and args.startswith(f"{self.app}/"):
                return pid, m.group(1)
        return None

    def worker_pid(self) -> int | None:
        for pid, args in self.procs():
            if "cmux-screen-sharing __computer-use-worker" in args and str(self.home) in args:
                return pid
        for pid, args in self.procs():
            if "cmux-screen-sharing __computer-use-worker" in args and self.helper_id in args:
                return pid
        return None

    def alive(self, pid: int | None) -> bool:
        if not pid:
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    # ---- the CLI ---------------------------------------------------------------------------------------------
    def cu(self, *words: str, timeout: float = 60) -> tuple[int, dict | str]:
        args = [str(self.cli)] + (["--session", self.session] if self.session else []) + ["--json", "computer-use", *words]
        code, o, e = sh(args, timeout=timeout, env=self.env)
        text = o.strip() or e.strip()
        try:
            return code, json.loads(text.splitlines()[-1]) if text else {}
        except (ValueError, IndexError):
            return code, text[-600:]

    @staticmethod
    def find(value, key: str):
        if isinstance(value, dict):
            if key in value:
                return value[key]
            for v in value.values():
                got = Run.find(v, key)
                if got is not None:
                    return got
        elif isinstance(value, list):
            for v in value:
                got = Run.find(v, key)
                if got is not None:
                    return got
        return None

    def perms(self, body) -> dict:
        p = self.find(body, "permissions") if isinstance(body, dict) else None
        return p if isinstance(p, dict) else {}

    @staticmethod
    def granted(v) -> bool:
        return v is True or (isinstance(v, str) and v.lower() in ("granted", "yes", "true", "ok"))

    def shot(self, name: str, window: str | None = None) -> tuple[int, dict | str]:
        f = self.out / f"{name}.png"
        words = ["screenshot", "--out", str(f)] + (["--window", window] if window else [])
        return self.cu(*words)

    # ---- parts -----------------------------------------------------------------------------------------------
    def part_a(self) -> dict:
        r: dict = {"pass": False}
        r["revoke"] = self.revoke()
        r["rows_after_revoke"] = self.rows()
        line(f"a: revoked {r['revoke']} rows now {r['rows_after_revoke']}")
        log = open(self.out / "app.log", "w")
        p = subprocess.Popen([str(self.app_exe)], env=self.env, stdout=log, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        self.started.append(p)
        t_launch = now()
        d = None
        while now() - t_launch < 180 and d is None:
            if p.poll() is not None:
                r["error"] = f"the app exited {p.returncode} at launch"
                return r
            d = self.daemon()
            if d is None:
                time.sleep(0.5)
        if d is None:
            r["error"] = "no daemon of this app came up in 180 s"
            return r
        daemon_pid, self.session = d
        r.update(app_pid=p.pid, daemon_pid=daemon_pid, session=self.session,
                 daemon_up_s=round(now() - t_launch, 2))
        line(f"a: app pid {p.pid}, daemon pid {daemon_pid} session {self.session} after {r['daemon_up_s']} s")
        # Before the grant: the worker starts on the first request and must read missing.
        t = now()
        before = None
        while now() - t < 90:
            code, body = self.cu("status")
            before = body
            if code == 0 and self.perms(body):
                break
            time.sleep(1)
        r["status_before"] = before
        pb = self.perms(before)
        r["permissions_before"] = pb
        line(f"a: status before the grant: {json.dumps(pb)} mode {self.find(before, 'mode') if isinstance(before, dict) else before}")
        if not pb:
            r["error"] = "computer-use status gave no permissions before the grant"
            return r
        if self.granted(pb.get("screen_capture")):
            r["error"] = "Screen Recording read granted before the grant: this Mac's TCC was not reset for the helper"
            return r
        code, body = self.shot("a-before")
        r["screenshot_before"] = {"exit": code, "body": body}
        line(f"a: screenshot before the grant: exit {code} {json.dumps(body)[:300]}")
        w_before = self.worker_pid()
        r["worker_pid_before"] = w_before
        # The grant, while the app, its daemon and the worker run.
        t_grant = now()
        r["grant"] = self.grant()
        r["rows_after_grant"] = self.rows()
        line(f"a: granted {r['grant']['user db']}/{r['grant']['system db']} rows {r['rows_after_grant']}")
        polls = []
        t_status = None
        while now() - t_grant < GRANT_DEADLINE:
            code, body = self.cu("status", timeout=15)
            pm = self.perms(body)
            polls.append({"t": round(now() - t_grant, 2), "exit": code, "permissions": pm or str(body)[:200]})
            if self.granted(pm.get("screen_capture")) and self.granted(pm.get("accessibility")):
                t_status = now() - t_grant
                break
            time.sleep(0.25)
        r["status_polls"] = polls
        r["status_granted_s"] = round(t_status, 2) if t_status is not None else None
        line(f"a: status granted after {r['status_granted_s']} s ({len(polls)} reads)")
        shots = []
        t_shot = None
        n = 0
        while now() - t_grant < GRANT_DEADLINE * 2:
            n += 1
            code, body = self.shot(f"a-after-{n}")
            ok = code == 0 and isinstance(body, dict) and (body.get("bytes") or 0) > 0
            shots.append({"t": round(now() - t_grant, 2), "exit": code, "body": body if not ok else {"bytes": body.get("bytes")}})
            if ok:
                t_shot = now() - t_grant
                break
            time.sleep(0.5)
        r["screenshot_polls"] = shots
        r["screenshot_ok_s"] = round(t_shot, 2) if t_shot is not None else None
        line(f"a: screenshot ok after {r['screenshot_ok_s']} s ({len(shots)} tries)")
        w_after = self.worker_pid()
        d_after = self.daemon()
        r.update(worker_pid_after=w_after, daemon_pid_after=d_after[0] if d_after else None,
                 app_alive=p.poll() is None)
        r["same_app_and_daemon"] = bool(p.poll() is None and d_after and d_after[0] == daemon_pid)
        code, after = self.cu("status")
        r["permissions_after"] = self.perms(after)
        r["pass"] = bool(t_status is not None and t_shot is not None and r["same_app_and_daemon"]
                         and t_status <= GRANT_DEADLINE and t_shot <= GRANT_DEADLINE)
        line(f"a: {'PASS' if r['pass'] else 'FAIL'}: worker {w_before} -> {w_after}, app/daemon unchanged "
             f"{r['same_app_and_daemon']}, status {r['status_granted_s']} s, screenshot {r['screenshot_ok_s']} s")
        return r

    def part_b(self) -> dict:
        r: dict = {"pass": False, "steps": {}}
        doc = self.work / "hfg.txt"
        doc.write_text("cmux helper fresh grant\n")
        before = {pid for pid, args in self.procs() if "/TextEdit.app/Contents/MacOS/TextEdit" in args}
        sh(["open", "-n", "-a", "TextEdit", str(doc)])
        te = None
        t = now()
        while now() - t < 20 and te is None:
            fresh = [pid for pid, args in self.procs() if "/TextEdit.app/Contents/MacOS/TextEdit" in args and pid not in before]
            te = fresh[0] if fresh else None
            time.sleep(0.5)
        if te:
            self.started_pids.append(te)
        r["textedit_pid"] = te
        time.sleep(2)
        code, apps = self.cu("call", "list_apps")
        names = json.dumps(apps)
        r["steps"]["list_apps"] = {"exit": code, "has_textedit": TEXTEDIT in names, "count": len(self.find(apps, "apps") or [])
                                   if isinstance(apps, dict) else None}
        code, wins = self.cu("call", "list_windows", "--args", json.dumps({"app_id": TEXTEDIT}))
        windows = (self.find(wins, "windows") or []) if isinstance(wins, dict) else []
        win = next((w for w in windows if "hfg" in str(w.get("title", ""))), windows[0] if windows else None)
        r["steps"]["list_windows"] = {"exit": code, "windows": [{k: w.get(k) for k in ("window_id", "title")} for w in windows]}
        if not win:
            r["error"] = f"no TextEdit window: {str(wins)[:300]}"
            return r
        wid = str(win.get("window_id"))
        code, body = self.shot("b-textedit", wid)
        png = self.out / "b-textedit.png"
        size = None
        if png.exists():
            head = png.read_bytes()[:24]
            if head[:8] == b"\x89PNG\r\n\x1a\n":
                size = struct.unpack(">II", head[16:24])
        r["steps"]["screenshot"] = {"exit": code, "size": size}
        if not size:
            r["error"] = f"no TextEdit screenshot: {str(body)[:300]}"
            return r
        # The text area: the window's middle, below the toolbar.
        x, y = size[0] // 2, int(size[1] * 0.6)
        code, body = self.cu("call", "click", "--args", json.dumps({"window_id": wid, "x": x, "y": y}))
        r["steps"]["click"] = {"exit": code, "at": [x, y], "body": str(body)[:300]}
        code, body = self.cu("call", "press_key", "--args", json.dumps({"window_id": wid, "keys": "cmd+down"}))
        r["steps"]["press_key"] = {"exit": code, "body": str(body)[:200]}
        code, body = self.cu("call", "type_text", "--args", json.dumps({"window_id": wid, "text": " " + TYPED}))
        r["steps"]["type_text"] = {"exit": code, "body": str(body)[:300]}
        time.sleep(1)
        code, tree = self.cu("call", "get_ui_tree", "--args", json.dumps({"window_id": wid}))
        r["steps"]["get_ui_tree"] = {"exit": code, "has_typed_text": TYPED in json.dumps(tree)}
        self.shot("b-textedit-after", wid)
        r["pass"] = bool(r["steps"]["list_apps"]["has_textedit"] and r["steps"]["click"]["exit"] == 0
                         and r["steps"]["type_text"]["exit"] == 0 and r["steps"]["get_ui_tree"]["has_typed_text"])
        line(f"b: {'PASS' if r['pass'] else 'FAIL'}: " + json.dumps({k: v.get("exit") for k, v in r["steps"].items()})
             + f" typed text read back {r['steps']['get_ui_tree']['has_typed_text']}")
        return r

    def part_c(self) -> dict:
        r: dict = {"pass": False}
        if not (self.viewer and Path(self.viewer).is_file() and Path(self.disclaim).is_file()):
            r["error"] = "the viewer or the disclaim launcher did not build"
            return r
        staged = sorted(self.home.glob(f"Library/Application Support/cmux-next/screen-sharing/{self.helper_id}/computer-use/**/Contents/MacOS/cmux-screen-sharing"))
        exe = staged[-1] if staged else None
        r["helper_executable"] = str(exe) if exe else None
        if not exe:
            r["error"] = "no staged helper copy (the daemon stages one when Computer Use starts)"
            return r
        if Path(self.marker).is_file():
            m = subprocess.Popen([self.marker, "--verbose"], stdout=open(self.out / "marker.log", "w"),
                                 stderr=subprocess.STDOUT, start_new_session=True)
            self.started.append(m)
            time.sleep(2)
        token = secrets.token_hex(32)
        rfd, wfd = os.pipe()
        os.write(wfd, token.encode())
        os.close(wfd)
        hostlog = open(self.out / "host.log", "w")
        # The token on fd 3 (the host's --token-fd), from a pipe on stdin.
        code = subprocess.run(["/bin/bash", "-c", 'exec "$@" 3<&0', "fd3", self.disclaim, str(exe), "host", "--owner",
                               "owner", "--bind", "127.0.0.1", "--port", "4103", "--profile", "baseline", "--token-fd", "3"],
                              stdin=rfd, stdout=subprocess.PIPE, stderr=hostlog, text=True, timeout=30)
        os.close(rfd)
        host_pid = int(code.stdout.strip()) if code.stdout.strip().isdigit() else None
        r["host_pid"] = host_pid
        if host_pid:
            self.started_pids.append(host_pid)
        time.sleep(3)
        r["host_alive"] = self.alive(host_pid)
        t = now()
        rfd, wfd = os.pipe()
        os.write(wfd, token.encode())
        os.close(wfd)
        try:
            b = subprocess.run(["/bin/bash", "-c", 'exec "$@" 3<&0', "fd3", self.viewer, "bench", "--addr", "127.0.0.1:4103",
                                "--samples", "20", "--user", "owner", "--token-fd", "3"], stdin=rfd, capture_output=True,
                               text=True, timeout=120)
            bench_code, bench_out = b.returncode, (b.stdout + b.stderr)
        except subprocess.TimeoutExpired as e:
            bench_code, bench_out = 124, str(e.stdout or "")
        os.close(rfd)
        (self.out / "bench.log").write_text(bench_out)
        r["bench_exit"] = bench_code
        r["bench_s"] = round(now() - t, 2)
        r["bench_tail"] = bench_out.strip().splitlines()[-8:]
        frames = re.findall(r'"(?:frames|decoded|samples_ok|ok)"\s*:\s*(\d+)', bench_out)
        r["frames_fields"] = frames[:10]
        r["pass"] = bool(bench_code == 0 and r["host_alive"])
        line(f"c: {'PASS' if r['pass'] else 'FAIL'}: host pid {host_pid} alive {r['host_alive']}, bench exit {bench_code} in {r['bench_s']} s")
        for l in r["bench_tail"]:
            line(f"c: bench: {l[:300]}")
        if host_pid and self.alive(host_pid):
            os.kill(host_pid, signal.SIGTERM)
        return r

    def teardown(self) -> None:
        for pid in self.started_pids:
            if self.alive(pid):
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
        for p in self.started:
            if p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(2)
        for p in self.started:
            if p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
        self.report["revoke_at_end"] = self.revoke()

    def main(self) -> int:
        verdicts = []
        try:
            for name, fn in (("a", self.part_a), ("b", self.part_b), ("c", self.part_c)):
                if name == "c" and not self.share:
                    continue
                if name != "a" and not self.session:
                    break
                try:
                    res = fn()
                except Exception as e:  # noqa: BLE001 - a part's crash is its verdict
                    res = {"pass": False, "error": f"{type(e).__name__}: {e}"}
                self.report["parts"][name] = res
                verdicts.append(res.get("pass") is True)
                if res.get("error"):
                    line(f"{name}: error: {res['error']}")
                self.save()
        finally:
            self.teardown()
            self.save()
        line("verdict " + " ".join(f"{k}={'PASS' if v.get('pass') else 'FAIL'}" for k, v in self.report["parts"].items()))
        return 0 if verdicts and all(verdicts) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--account-home", required=True)
    ap.add_argument("--viewer", default="")
    ap.add_argument("--marker", default="")
    ap.add_argument("--disclaim", default="")
    ap.add_argument("--share", default="1")
    return Run(ap.parse_args()).main()


if __name__ == "__main__":
    sys.exit(main())
