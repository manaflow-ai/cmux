#!/usr/bin/env python3
"""Record cmux's GitHub main path on staging: a new user connects GitHub, then opens a PR from a Cloud chat.

Run by cloud-chat-proof.yml with `flow: github-pr-app` (build=tagged: it drives the app through the Debug build's
`debug.*` socket methods), after cloud-github-config-check.py. The click path, what reads each step back, the
expected times and what to do on a GitHub verification page: docs/cmux-next/cloud-github-main-path-recording.md.

1. sign in: the tagged app starts signed in to the staging capture account (its credentials file, as the chat proof).
2. connect: Connect GitHub (`accounts.githubConnect`, Settings > Accounts > GitHub's button); its page opens in a
   cmux browser tab.
3. github: in that tab, GitHub's sign-in as the test user (password, then a TOTP code from the seed), the App's
   install on the test org, only the one repository, Install.
4. back: GitHub returns to `<scheme>://integration/complete`; the staging API reads the connection active and lists
   the repository.
5. chat: a new chat, its folder `github:ORG/REPO`, Cloud, and the ask: a branch, a README change, a PR.
6. pr: the PR is on GitHub (read in the same tab) and the tab opens it.

Every step records its time and its clicks (each click, fill or send the script makes counts one) in DIR/steps.json
and DIR/summary.md, and the main window is captured every --frame-interval seconds into DIR/frames (made into
DIR/github-main-path.mp4 when ffmpeg is there). Frames pause while the TOTP code is on screen. The first step that
does not read back fails the run with its reason and a retry hint.

Secrets come only from the environment and are never printed: CMUX_GITHUB_TEST_LOGIN, _PASSWORD, _TOTP_SEED (the
GitHub test user), CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD (the staging account, step 4's read), and
CLAUDE_CODE_OAUTH_TOKEN (the chat's Claude login, as the chat proof). The TOTP code is masked (`::add-mask::`)
before it is used. `--dry-run` stops before GitHub's sign-in and needs none of the GitHub secrets.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_login_cache  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
parser.add_argument("--app", required=True, help="the tagged app bundle (build=tagged)")
parser.add_argument("--tag", required=True)
parser.add_argument("--credentials-file", required=True, help="0600 Stack credentials file the app reads at launch")
parser.add_argument("--out", required=True, help="where steps.json, summary.md, frames/ and the video go")
parser.add_argument("--org", default="cmux-cloud-test-org")
parser.add_argument("--repo", default="pr-target")
parser.add_argument("--slug", default="cmux-cloud-staging", help="the staging GitHub App")
parser.add_argument("--api", default="https://cloud-api-staging.cmux.dev")
parser.add_argument("--frame-interval", type=float, default=1.0)
parser.add_argument("--close-pr", action="store_true", help="close the PR in GitHub's page after step 6")
parser.add_argument("--dry-run", action="store_true", help="steps 1-2 only: stop before GitHub's sign-in")
args = parser.parse_args()

OUT = Path(args.out)
FRAMES = OUT / "frames"
FRAMES.mkdir(parents=True, exist_ok=True)
CLI = str(Path(args.app) / "Contents/Resources/bin/cmux")
SOCKET_PATH = f"/tmp/cmux-debug-{args.tag}.sock"
ENV = {**os.environ, "CMUX_SOCKET_PATH": SOCKET_PATH, "CMUX_NEXT_SOCKET_PATH": SOCKET_PATH}
SECRET_NAMES = ("CMUX_GITHUB_TEST_PASSWORD", "CMUX_GITHUB_TEST_TOTP_SEED", "CMUX_DOGFOOD_STACK_PASSWORD",
                claude_login_cache.TOKEN_ENV)
for name in SECRET_NAMES:  # no CLI call inherits a secret
    ENV.pop(name, None)
REPO = f"{args.org}/{args.repo}"
BRANCH = f"cmux-recording-{args.tag}"[:60]
RETRY = {
    "sign in": "rerun; if it repeats, rotate the staging account (cloud-capture-provision.yml target journey)",
    "connect": "rerun; if Connect GitHub says not configured, run the config check (staging API App settings)",
    "github": "read DIR/frames for the page GitHub showed; a device-verification or 2FA page: see the doc's "
              "'GitHub asks for more' section, then rerun",
    "back": "rerun; if GitHub installed the App but cmux shows nothing, open Settings > Accounts and press Refresh, "
            "and check the App's setup URL points at the staging console",
    "chat": "rerun; the chat's own card says why (no Claude login, no machine); the machine is killed at the end",
    "pr": "rerun; the PR list of the repo shows whether the agent pushed a branch (name in steps.json)",
}

steps: list[dict] = []
state = {"step": None, "t0": 0.0, "clicks": 0, "typed": 0, "paused": False, "stop": False}


def say(text: str) -> None:
    print(text, flush=True)


def scrub(text: str, limit: int = 400) -> str:
    text = (text or "").strip()
    for name in SECRET_NAMES + ("CMUX_GITHUB_TEST_LOGIN", "CMUX_DOGFOOD_STACK_EMAIL"):
        value = os.environ.get(name, "")
        if len(value) >= 4:
            text = text.replace(value, "***")
    text = re.sub(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", "***", text)
    text = re.sub(r"\bgh[pousr]_[A-Za-z0-9]{16,}", "***", text)
    return text[:limit]


def cmux(*words: str, timeout: int = 120) -> tuple[int, str, str]:
    try:
        done = subprocess.run([CLI, *words], env=ENV, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"


def parsed(text: str) -> dict:
    for candidate in [text, *reversed((text or "").splitlines())]:
        try:
            value = json.loads(candidate)
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(value, dict):
            inner = value.get("result", value)
            return inner if isinstance(inner, dict) else {"value": inner}
    return {}


def app_call(method: str, params: dict, timeout: int = 60) -> dict:
    code, out, err = cmux("app", "call", method, json.dumps(params), "--json", timeout=timeout)
    value = parsed(out)
    if code != 0 and "error" not in value:
        value["error"] = scrub(err or out) or f"exit {code}"
    return value


def poll(seconds: float, probe, step: float = 2.0):
    deadline = time.monotonic() + seconds
    while True:
        value = probe()
        if value or time.monotonic() >= deadline:
            return value
        time.sleep(step)


# The recording: the main window as the app draws it (debug.window_snapshot, no Screen Recording grant needed).
def frames() -> None:
    n = 0
    while not state["stop"]:
        if not state["paused"]:
            n += 1
            app_call("debug.window_snapshot", {"kind": "main", "path": str(FRAMES / f"frame-{n:05d}.png")}, timeout=20)
        time.sleep(args.frame_interval)


def begin(name: str) -> None:
    state.update(step=name, t0=time.monotonic(), clicks=0, typed=0)
    say(f"== step {len(steps) + 1}: {name}")


def click(n: int = 1) -> None:
    state["clicks"] += n


def done(detail: str) -> None:
    steps.append({"step": state["step"], "ok": True, "seconds": round(time.monotonic() - state["t0"], 1),
                  "clicks": state["clicks"], "typed": state["typed"], "detail": scrub(detail)})
    say(f"[ok] {state['step']}: {steps[-1]['seconds']} s, {state['clicks']} clicks, {state['typed']} fields typed; "
        f"{steps[-1]['detail']}")


def fail(detail: str) -> None:
    name = state["step"] or "setup"
    steps.append({"step": name, "ok": False, "seconds": round(time.monotonic() - state["t0"], 1),
                  "clicks": state["clicks"], "typed": state["typed"], "detail": scrub(detail)})
    say(f"::error::step '{name}' did not read back: {scrub(detail)}. Retry: {RETRY.get(name, 'rerun')}")
    finish(f"fail: {name}")


# ---- GitHub's pages, in the cmux browser tab Connect GitHub opened ----
def browser(tab: str, *words: str, timeout: int = 60) -> tuple[int, str, str]:
    return cmux("--json", "browser", tab, *words, timeout=timeout)


def tab_url(tab: str) -> str:
    code, out, _ = browser(tab, "state", timeout=20)
    if code != 0:
        return ""
    value = parsed(out)
    inner = value.get("value") if isinstance(value.get("value"), dict) else value
    return str(inner.get("url") or "")


def browser_tabs() -> list[str]:
    code, out, _ = cmux("--json", "tab", "list", timeout=30)
    found: list[str] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            if node.get("content_kind") == "browser" and str(node.get("id", "")).startswith("tab_"):
                found.append(node["id"])
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)
    if code == 0:
        try:
            walk(json.loads(out))
        except json.JSONDecodeError:
            pass
    return found


def js(tab: str, script: str) -> str:
    """Run SCRIPT in the page; its value as text ('' on an error)."""
    code, out, _ = browser(tab, "eval", script, timeout=30)
    if code != 0:
        return ""
    value = parsed(out)
    got = value.get("value", value.get("result", out))
    return got if isinstance(got, str) else json.dumps(got)


def click_text(tab: str, selector: str, pattern: str) -> bool:
    """Click the first SELECTOR element whose text matches PATTERN (a JS regex, case-insensitive)."""
    script = (f"(() => {{ const re = new RegExp({json.dumps(pattern)}, 'i');"
              f" const el = [...document.querySelectorAll({json.dumps(selector)})]"
              ".find(e => re.test((e.innerText || e.value || e.getAttribute('aria-label') || '').trim()));"
              " if (!el) return 'missing'; el.scrollIntoView({block: 'center'}); el.click(); return 'clicked'; })()")
    ok = "clicked" in js(tab, script)
    if ok:
        click()
    return ok


def fill(tab: str, selector: str, text: str) -> bool:
    code, _, _ = browser(tab, "fill", selector, text, timeout=30)
    if code == 0:
        state["typed"] += 1
    return code == 0


def has(tab: str, selector: str) -> bool:
    return "yes" in js(tab, f"document.querySelector({json.dumps(selector)}) ? 'yes' : 'no'")


def totp(seed: str, at: float | None = None) -> str:
    """RFC 6238: six digits, 30 s, SHA-1 (what GitHub's authenticator setup uses)."""
    key = base64.b32decode(re.sub(r"\s", "", seed).upper() + "=" * (-len(re.sub(r"\s", "", seed)) % 8))
    counter = int((at or time.time()) // 30)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    return f"{(struct.unpack('>I', digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000:06d}"


def github_page(tab: str) -> str:
    """Which GitHub page the tab shows, by its URL: login, 2fa, device, sudo, install, permissions, other."""
    url = tab_url(tab)
    if "/sessions/verified-device" in url:
        return "device"
    if "/login/oauth/authorize" in url:
        return "authorize"
    if "/sessions/two-factor" in url:
        return "2fa"
    if url.rstrip("/").endswith("/login") or "/login?" in url or url.endswith("/session"):
        return "login"
    if "/sudo" in url or (has(tab, "#sudo_password") if "github.com" in url else False):
        return "sudo"
    if "/installations/new/permissions" in url:
        return "permissions"
    if "/installations/new" in url:
        return "install"
    return "other" if "github.com" in url else ("left" if url else "")


# ---- the run ----
app_launcher = None
FRAME_THREAD = threading.Thread(target=frames, daemon=True)
CONFIG_DIR = os.path.realpath(tempfile.mkdtemp(prefix="cmux-github-path-"))
CONFIG_FILE = Path(CONFIG_DIR, "cmux-next.json")
CACHED_LOGINS: list[str] = []
machines_before: set[str] | None = None  # None until read: a failure before that kills nothing


def machine_ids() -> set[str]:
    code, out, _ = cmux("cloud", "list-machines", "--json", timeout=60)
    rows = parsed(out).get("machines") or [] if code == 0 else []
    return {r["machine_id"] for r in rows if isinstance(r, dict) and r.get("machine_id")}


def finish(result: str) -> None:
    state["stop"] = True
    # The chat's machine goes, pass or fail; only machines this run made.
    if machines_before is not None and app_launcher is not None:
        for machine in sorted(machine_ids() - machines_before):
            code, _, err = cmux("cloud", "kill-machine", machine, "--json", timeout=120)
            say(f"kill machine {machine}: exit {code} {scrub(err, 160)}")
    while CACHED_LOGINS:
        code, err = claude_login_cache.remove(CLI, ENV, CACHED_LOGINS.pop())
        if code != 0:
            say(f"::warning::cached Claude login not removed: exit {code}")
    if app_launcher is not None:
        cmux("app", "quit", "--json", timeout=30)
        try:
            app_launcher.wait(timeout=60)
        except subprocess.TimeoutExpired:
            say("::warning::the app did not exit within 60 s")
    shutil.rmtree(CONFIG_DIR, ignore_errors=True)
    if FRAME_THREAD.is_alive():
        FRAME_THREAD.join(timeout=30)
    video = OUT / "github-main-path.mp4"
    if shutil.which("ffmpeg") and any(FRAMES.glob("frame-*.png")):
        # Frame numbers skip while paused (the TOTP code); renumber so ffmpeg reads one sequence.
        for i, frame in enumerate(sorted(FRAMES.glob("frame-*.png")), 1):
            frame.rename(FRAMES / f"seq-{i:05d}.png")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(1 / args.frame_interval), "-i",
                        str(FRAMES / "seq-%05d.png"), "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p",
                        str(video)], check=False)
        if video.is_file() and video.stat().st_size > 0:
            shutil.rmtree(FRAMES, ignore_errors=True)  # the video holds them; the artifact stays small
    total = round(sum(s["seconds"] for s in steps), 1)
    lines = [f"## GitHub main path ({result})", "", "| # | step | ok | seconds | clicks | fields typed | read back |",
             "|---|---|---|---|---|---|---|"]
    lines += [f"| {i} | {s['step']} | {'yes' if s['ok'] else 'NO'} | {s['seconds']} | {s['clicks']} | {s.get('typed', 0)} | "
              f"{s['detail'].replace('|', '/')} |"
              for i, s in enumerate(steps, 1)]
    lines += ["", f"Total {total} s, {sum(s['clicks'] for s in steps)} clicks. Video: "
              f"{video.name if video.is_file() else 'frames/ (no ffmpeg)'}."]
    (OUT / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (OUT / "steps.json").write_text(json.dumps({"result": result, "repo": REPO, "branch": BRANCH, "steps": steps},
                                               indent=2) + "\n", encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write("\n".join(lines) + "\n")
    say("\n".join(lines))
    sys.exit(0 if result == "pass" else 1)


def api_get(token: str, path: str) -> tuple[int, dict]:
    request = urllib.request.Request(f"{args.api.rstrip('/')}{path}", headers={"authorization": f"Bearer {token}",
                                                                               "accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        return exc.code, {}
    except (urllib.error.URLError, TimeoutError, ValueError):
        return 0, {}


def main() -> None:
    global app_launcher, machines_before
    login = os.environ.get("CMUX_GITHUB_TEST_LOGIN", "")
    password = os.environ.get("CMUX_GITHUB_TEST_PASSWORD", "")
    seed = os.environ.get("CMUX_GITHUB_TEST_TOTP_SEED", "")
    claude = claude_login_cache.token_from(os.environ)
    if not args.dry_run:
        missing = [n for n, v in (("CMUX_GITHUB_TEST_LOGIN", login), ("CMUX_GITHUB_TEST_PASSWORD", password),
                                  ("CMUX_GITHUB_TEST_TOTP_SEED", seed), ("CMUX_DOGFOOD_STACK_EMAIL",
                                  os.environ.get("CMUX_DOGFOOD_STACK_EMAIL")), ("CMUX_DOGFOOD_STACK_PASSWORD",
                                  os.environ.get("CMUX_DOGFOOD_STACK_PASSWORD"))) if not v]
        if missing:
            fail(f"not set in this job's environment: {', '.join(missing)} (seal them into cmux-next-cloud-journey)")
        try:
            totp(seed)
        except (ValueError, binascii.Error):
            fail("CMUX_GITHUB_TEST_TOTP_SEED is not a base32 TOTP seed")
        if not claude_login_cache.valid(claude):
            fail(f"{claude_login_cache.TOKEN_ENV} is not a `claude setup-token` login (the chat in step 5 needs it)")

    # The app's own scratch cmux.json: GitHub's pages open in a cmux browser tab (so the run can drive and record
    # them), and the one-time Claude login consent (as cloud-chat-proof.py --grant-claude-login).
    CONFIG_FILE.touch(mode=0o600)
    CONFIG_FILE.write_text(json.dumps({"browser": {"openLinksInCmuxBrowser": True},
                                       "cloud": {"useMyClaudeLoginOnMyCloudMachines": True}}, indent=2) + "\n")
    ENV["CMUX_NEXT_CONFIG_FILE"] = str(CONFIG_FILE)

    begin("sign in")
    launch = ["/usr/bin/open", "-W", "-g", "-n", "--env", f"CMUX_NEXT_SOCKET_PATH={SOCKET_PATH}",
              "--env", f"CMUX_NEXT_CONFIG_FILE={CONFIG_FILE}",
              "--env", f"CMUX_AUTH_CREDENTIALS_FILE={os.path.realpath(args.credentials_file)}",
              "--env", "CMUX_DEV_AUTH_PROFILE=agent", "--env", "CMUX_DEV_AUTH_REPLACE_SESSION=1",
              str(Path(args.app).resolve()), "--args", "--cloud-backend", "staging"]
    app_launcher = subprocess.Popen(launch, env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    auth = poll(240, lambda: (lambda v: v if v.get("signed_in") is True and v.get("cloud_environment") == "staging"
                              else None)(app_call("auth.status", {}, timeout=30)), step=5)
    if not auth:
        fail("the app did not read signed in on staging within 240 s (auth.status)")
    FRAME_THREAD.start()
    if claude:
        for entry in claude_login_cache.names(auth):
            CACHED_LOGINS.append(entry)
            code, err = claude_login_cache.store(CLI, ENV, entry, claude)
            if code != 0:
                fail(f"caching the chat's Claude login: exit {code} {err}")
    machines_before = machine_ids()
    done(f"signed in on staging ({auth.get('backend', '?')})")

    begin("connect")
    tabs_before = set(browser_tabs())
    code, out, err = cmux("--json", "accounts", "github-connect", timeout=90)
    click()
    answer = parsed(out)
    if code != 0 or answer.get("status") == "connected":
        fail("Connect GitHub refused: " + (err or out) if code != 0 else
             "the team is already connected; disconnect it (Settings > Accounts > GitHub > Disconnect) and uninstall "
             f"the App from {args.org} so the run starts as a new user")
    tab = poll(60, lambda: next((t for t in browser_tabs() if t not in tabs_before and "github.com" in tab_url(t)), None))
    if not tab:
        fail(f"no cmux browser tab opened on github.com within 60 s (Connect GitHub said {answer.get('status')}: "
             f"{answer.get('detail', '')})")
    done(f"Connect GitHub ({answer.get('status')}) opened GitHub in {tab}")
    if args.dry_run:
        finish("pass")

    begin("github")
    deadline = time.monotonic() + 300
    installed = pressed = False
    others = 0
    while time.monotonic() < deadline and not installed:
        page = poll(30, lambda: github_page(tab), step=1)
        if page == "login":
            if not (fill(tab, "#login_field", login) and fill(tab, "#password", password)
                    and click_text(tab, "input[type=submit], button[type=submit]", "^sign in$")):
                fail("GitHub's sign-in page: the login form did not take the test user")
        elif page == "2fa":
            state["paused"] = True  # no frame shows the code
            code = totp(seed)
            if time.time() % 30 > 25:  # too close to the window's end: take the next one
                time.sleep(30 - time.time() % 30 + 1)
                code = totp(seed)
            say(f"::add-mask::{code}")
            field = next((s for s in ("#app_totp", "#otp", "input[name=app_otp]", "input[name=otp]") if has(tab, s)), "")
            if not field or not fill(tab, field, code):
                state["paused"] = False
                fail("GitHub's 2FA page has no authenticator code field (it may ask for another method: see the doc)")
            click_text(tab, "button[type=submit], input[type=submit]", "^verify")
            time.sleep(3)
            state["paused"] = False
        elif page == "authorize":
            # The App asks for user authorization with its install: Authorize.
            if not click_text(tab, "button[type=submit], input[type=submit], button", "^authorize"):
                fail("GitHub's Authorize page has no Authorize button")
        elif page == "device":
            fail("GitHub asked to verify a new device (an emailed code); the TOTP seed does not answer it")
        elif page == "sudo":
            if not (fill(tab, "#sudo_password", password) and click_text(tab, "button[type=submit]", "^confirm")):
                fail("GitHub's Confirm access page did not take the password")
        elif page == "install":
            # The account picker: the org's row (its link, or Configure when the App is on it already).
            if not click_text(tab, "a, button", rf"^{re.escape(args.org)}\b|{re.escape(args.org)}$"):
                fail(f"GitHub's install page lists no {args.org} (the App is private, or the user is no org owner)")
        elif page == "permissions":
            if not click_text(tab, "label, input[type=radio]", "only select repositories"):
                fail("GitHub's install page has no 'Only select repositories' choice")
            click_text(tab, "summary, button", "select repositories")
            time.sleep(1)
            field = next((s for s in ("#repository-menu-filter-field", "input[placeholder*='Search for a repository']",
                                      "input[aria-label*='repositor' i]") if has(tab, s)), "")
            if field:
                fill(tab, field, args.repo)
                time.sleep(2)
            if not click_text(tab, "[role=menuitem], [role=menuitemcheckbox], [role=option], label, button",
                              rf"(^|/){re.escape(args.repo)}$"):
                fail(f"the repository picker did not offer {args.repo}")
            if not click_text(tab, "button[type=submit], input[type=submit]", "^install"):
                fail("GitHub's install page has no Install button")
            pressed = True
        elif page == "left":
            installed = pressed  # GitHub handed the tab to the console and cmux (its setup URL)
            if not pressed:
                fail(f"the tab left GitHub before Install ({tab_url(tab)[:120]})")
        elif page == "other":
            # After Install, a GitHub page with no setup URL to follow (the installation's settings): done.
            others += 1
            installed = pressed and others >= 5
            time.sleep(2)
        else:
            fail("the GitHub tab closed or reads no URL")
    if not installed:
        fail(f"GitHub's pages did not reach Install within 300 s (last page: {tab_url(tab)[:120]})")
    done(f"signed in, installed {args.slug} on {args.org} for {args.repo} only")

    begin("back")
    import importlib.util
    spec = importlib.util.spec_from_file_location("dev_signin_token", Path(__file__).resolve().parent / "dev-signin-token.py")
    signin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signin)
    token = signin.sign_in(os.environ["CMUX_DOGFOOD_STACK_EMAIL"], os.environ["CMUX_DOGFOOD_STACK_PASSWORD"])["accessToken"]
    team = auth.get("team_id") if isinstance(auth.get("team_id"), str) else ""
    queries = [""] + ([f"?team={team}"] if team else [])

    def connected() -> str | None:
        for q in queries:
            status, body = api_get(token, f"/v1/integrations/github/status{q}")
            if status == 200 and (body.get("connection") or {}).get("status") == "active":
                status, listed = api_get(token, f"/v1/integrations/github/repos{q}")
                names = [r if isinstance(r, str) else r.get("full_name", "") for r in listed.get("repos") or []]
                if any(n.lower() == REPO.lower() for n in names):
                    return f"connection active, {len(names)} repo(s) listed, {REPO} among them"
        return None
    read = poll(120, connected, step=4)
    if not read:
        fail(f"the staging API did not read the connection active with {REPO} listed within 120 s "
             f"(the tab is at {tab_url(tab)[:120]})")
    done(read)

    begin("chat")
    for method, params in (("action.run", {"action": "palette.newAgentChat", "focus": True}),
                           ("debug.agent_pane", {"action": "pick_folder", "cwd": f"github:{REPO}"}),
                           ("debug.agent_pane", {"action": "run_mode", "mode": "cloud"})):
        value = app_call(method, params)
        click()
        if value.get("error"):
            fail(f"{method} {params.get('action')}: {value['error']}")
        time.sleep(2)
    ask = (f"In this repository, make a branch named {BRANCH}, add one line to README.md that says "
           f"'Edited by the cmux GitHub recording {args.tag}.', commit it, push the branch and open a pull request "
           f"against the default branch. Reply with the pull request's URL.")
    value = app_call("debug.agent_pane", {"action": "compose_send", "text": ask})
    click()
    if value.get("error"):
        fail(f"compose_send: {value['error']}")
    done(f"a Cloud chat on github:{REPO} took the ask (branch {BRANCH})")

    begin("pr")
    pr_re = re.compile(rf"https://github\.com/{re.escape(REPO)}/pull/(\d+)", re.I)

    def pr_url() -> str | None:
        # The chat's link first (as drawn), else GitHub's own list of PRs from the branch, in the signed-in tab.
        found = pr_re.search(json.dumps(app_call("debug.agent_pane", {"action": "chat_state"})))
        if found:
            return found.group(0)
        browser(tab, "navigate", f"https://github.com/{REPO}/pulls?q=is%3Apr+head%3A{BRANCH}", timeout=30)
        # The PR list loaded: the tab is at the list and the document is complete.
        poll(20, lambda: "/pulls" in tab_url(tab) and js(tab, "document.readyState") == "complete", step=0.5)
        found = pr_re.search(js(tab, "[...document.querySelectorAll('a[href*=\"/pull/\"]')].map(a => a.href).join(' ')"))
        return found.group(0) if found else None
    url = poll(900, pr_url, step=20)
    if not url:
        fail(f"no PR from {BRANCH} within 15 minutes (neither in the chat nor on GitHub)")
    browser(tab, "navigate", url, timeout=30)
    click()
    ok = poll(30, lambda: BRANCH in js(tab, "document.body.innerText"), step=2)
    if not ok:
        fail(f"{url} opened, but the page does not name the branch {BRANCH}")
    detail = f"{url} open, from {BRANCH}"
    if args.close_pr:
        detail += "; closed" if click_text(tab, "button", "^close pull request$") else "; close button not found"
    done(detail)
    time.sleep(3)  # sleep-ok: the recording's last 3 s hold the PR page (a recording window)
    finish("pass")


try:
    main()
except SystemExit:
    raise
except Exception as exc:  # a harness fault still writes its summary and kills its machine
    steps.append({"step": state["step"] or "setup", "ok": False, "seconds": 0, "clicks": 0,
                  "detail": scrub(f"{type(exc).__name__}: {exc}")})
    finish(f"fail: {type(exc).__name__}")
