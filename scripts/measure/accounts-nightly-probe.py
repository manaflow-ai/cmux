#!/usr/bin/env python3
"""Drive the published NIGHTLY Accounts > GitHub App path and record person-path evidence.

The driver deliberately uses release APIs (action.run, the app CLI, and CuaDriver AX clicks), never debug.*
methods. It writes result.json, summary.md, and screenshots under --out and exits non-zero when the Accounts page,
GitHub browser handoff, installation, or repository readback cannot be observed.
"""
from __future__ import annotations
import argparse, base64, hashlib, hmac, importlib.util, json, os, re, struct, subprocess, sys, time
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
lkr_spec = importlib.util.spec_from_file_location("lkr", HERE / "look-keys-readback.py")
lkr = importlib.util.module_from_spec(lkr_spec); assert lkr_spec.loader; lkr_spec.loader.exec_module(lkr)
# Avoid importing customizer-toggle-readback.py's argparse-driven main: only copy the small AX routines below.

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", required=True)
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--api", default="https://cloud-api-staging.cmux.dev")
parser.add_argument("--org", default="cmux-cloud-test-org")
parser.add_argument("--repo", default="pr-target")
parser.add_argument("--cli", help="the NIGHTLY app's cmux CLI")
args = parser.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
SHOTS = OUT / "screenshots"; SHOTS.mkdir(exist_ok=True)
CLI = args.cli or str(Path(args.app) / "Contents/Resources/bin/cmux")
REPO = f"{args.org}/{args.repo}"
SECRETS = ("CMUX_GITHUB_TEST_PASSWORD", "CMUX_GITHUB_TEST_TOTP_SEED", "CMUX_UITEST_STACK_PASSWORD",
           "CMUX_DOGFOOD_STACK_PASSWORD")
steps: list[dict] = []
APP_META: dict = {}

def scrub(value: object) -> str:
    text = str(value or "")
    for name in SECRETS + ("CMUX_GITHUB_TEST_LOGIN", "CMUX_UITEST_STACK_EMAIL", "CMUX_DOGFOOD_STACK_EMAIL"):
        v = os.environ.get(name, "")
        if len(v) >= 4: text = text.replace(v, "***")
    text = re.sub(r"\b(?:eyJ|gh[pousr]_)[A-Za-z0-9_.-]{16,}", "***", text)
    return text[:500]

def record(name: str, ok: bool, detail: str, shot: str | None = None):
    item = {"step": name, "ok": ok, "detail": scrub(detail)}
    if shot: item["screenshot"] = shot
    steps.append(item)
    print(("PASS" if ok else "FAIL"), name, item["detail"], flush=True)
    return ok

def ax_elements(pid: int) -> list[dict]:
    found: list[dict] = []
    def visit(node, wid):
        if isinstance(node, dict):
            if "role" in node and ("element_token" in node or "element_index" in node): found.append(dict(node, _window=wid))
            for value in node.values(): visit(value, wid)
        elif isinstance(node, list):
            for value in node: visit(value, wid)
    for window in lkr.cua("list_windows", {"pid": pid}).get("windows") or []:
        if isinstance(window, dict) and window.get("window_id") is not None:
            state = lkr.cua("get_window_state", {"pid": pid, "window_id": window["window_id"],
                "include_screenshot": False, "max_depth": 80, "max_elements": 8000})
            visit(state, window["window_id"])
    return found

def label(e: dict) -> str:
    for key in ("label", "title", "value", "description", "name"):
        if str(e.get(key) or "").strip(): return str(e[key]).strip()
    return ""

def element_key(e: dict) -> tuple:
    return (e.get("_window"), e.get("element_token", e.get("element_index")))

def find_labelled(pid: int, text: str, skip: tuple | None = None) -> dict | None:
    # A word start, so "Connect GitHub" never matches "Disconnect GitHub".
    needle = re.compile(r"(?<![a-z])" + re.escape(text.lower()))
    return next((e for e in ax_elements(pid) if needle.search(label(e).lower()) and element_key(e) != skip), None)

def press(pid: int, e: dict) -> dict:
    token = {"element_token": e["element_token"]} if "element_token" in e else {"element_index": e["element_index"]}
    return lkr.cua("click", {"pid": pid, "window_id": e["_window"], **token, "action": "press"})

def shot(name: str) -> str:
    value = lkr.shoot(args.pid, SHOTS, name)
    return str(value.get("window") or value.get("desktop") or "")

def wait_for(fn, seconds: float, step: float = 1.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = fn()
        if value: return value
        time.sleep(step)
    return fn()

def cli(*words: str, timeout: int = 90) -> tuple[int, str, str]:
    env = dict(os.environ); env["CMUX_SOCKET_PATH"] = args.socket
    try:
        p = subprocess.run([CLI, *words], env=env, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as exc: return 124, "", str(exc)

def parsed(text: str):
    for line in reversed((text or "").splitlines()):
        try: return json.loads(line)
        except json.JSONDecodeError: continue
    return {}

def tabs() -> list[str]:
    code, out, _ = cli("--json", "tab", "list", timeout=30); result=[]
    def walk(v):
        if isinstance(v, dict):
            if v.get("content_kind") == "browser" and str(v.get("id", "")).startswith("tab_"): result.append(v["id"])
            for x in v.values(): walk(x)
        elif isinstance(v, list):
            for x in v: walk(x)
    if code == 0:
        try: walk(json.loads(out))
        except json.JSONDecodeError: pass
    return result

def browser(tab: str, *words: str): return cli("--json", "browser", tab, *words, timeout=30)
def url(tab: str) -> str:
    code, out, _ = browser(tab, "state"); value = parsed(out)
    if code != 0: return ""
    inner = value.get("value", value)
    return str(inner.get("url", "")) if isinstance(inner, dict) else ""
def js(tab: str, script: str) -> str:
    code, out, _ = browser(tab, "eval", script); value = parsed(out)
    got = value.get("value", value.get("result", ""))
    return got if isinstance(got, str) else json.dumps(got)
def click_text(tab: str, pattern: str) -> bool:
    script = "(() => { const re=new RegExp(%s,'i'); const e=[...document.querySelectorAll('a,button,input[type=submit],input[type=radio],label,summary')].find(x=>re.test((x.innerText||x.value||x.getAttribute('aria-label')||'').trim())); if(!e)return 'missing'; e.click(); return 'clicked'; })()" % json.dumps(pattern)
    return "clicked" in js(tab, script)
def fill(tab: str, selector: str, value: str) -> bool: return browser(tab, "fill", selector, value)[0] == 0
def page(tab: str) -> str:
    u = url(tab)
    if "/sessions/two-factor" in u: return "2fa"
    if "/sessions/verified-device" in u: return "device"
    if "/login/oauth/authorize" in u: return "authorize"
    if u.rstrip("/").endswith("/login") or "/login?" in u: return "login"
    if "/sudo" in u: return "sudo"
    if "/installations/new/permissions" in u: return "permissions"
    if "/installations/new" in u: return "install"
    return "left" if u and "github.com" not in u else ("other" if u else "")

def totp(seed: str) -> str:
    raw = re.sub(r"\s", "", seed).upper(); key = base64.b32decode(raw + "=" * (-len(raw) % 8))
    digest = hmac.new(key, struct.pack(">Q", int(time.time() // 30)), hashlib.sha1).digest(); off = digest[-1] & 15
    return f"{(struct.unpack('>I', digest[off:off+4])[0] & 0x7fffffff) % 1000000:06d}"

def api_get(token: str, path: str):
    import urllib.request
    req = urllib.request.Request(args.api.rstrip("/") + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as response: return response.status, json.loads(response.read())
    except Exception as exc: return 0, {"error": str(exc)}

def reset_existing_connection(pid: int) -> bool:
    """Make the scheduled probe idempotent when the shared test account is still connected."""
    disconnect = find_labelled(pid, "Disconnect")
    if not disconnect:
        return True
    first = press(pid, disconnect)
    if first.get("error"):
        return False
    # The confirmation's own Disconnect, not the row's button just pressed.
    confirm = wait_for(lambda: find_labelled(pid, "Disconnect", skip=element_key(disconnect)), 10)
    if not confirm:
        return False
    second = press(pid, confirm)
    if second.get("error"):
        return False
    return bool(wait_for(lambda: find_labelled(pid, "Connect GitHub"), 30))


def _run_probe() -> int:
    global APP_META
    meta = {}
    try:
        import plistlib
        with open(Path(args.app) / "Contents/Info.plist", "rb") as f: meta = plistlib.load(f)
    except Exception: pass
    APP_META = meta
    cold = shot("cold")
    if not record("cold launch", bool(cold), "release window captured", cold): return 1
    opened = lkr.rpc(args.socket, "action.run", {"action": "openSettings", "focus": True}, timeout=60)
    accounts = wait_for(lambda: find_labelled(args.pid, "accounts"), 45)
    accounts_shot = shot("accounts")
    if not record("Accounts page", bool(accounts), f"openSettings={opened}", accounts_shot): return 1
    # A person clicks the Accounts section, then the visible Connect GitHub control.
    if accounts: press(args.pid, accounts)
    if not record("Reset existing GitHub connection", reset_existing_connection(args.pid), "idempotent account teardown", shot("connection-reset")): return 1
    connect = wait_for(lambda: find_labelled(args.pid, "Connect GitHub"), 30)
    if not record("Connect GitHub visible", bool(connect), "AX label readback", shot("connect-visible")): return 1
    before = set(tabs()); pressed = press(args.pid, connect)
    clicked = bool(pressed.get("ok", True)) and not pressed.get("error")
    if not record("Connect GitHub clicked", clicked, "AX press issued", shot("connect-clicked")): return 1
    tab = wait_for(lambda: next((t for t in tabs() if t not in before and "github.com" in url(t)), None), 60)
    if not record("GitHub browser handoff", bool(tab), "new in-app GitHub tab", shot("github-handoff")): return 1
    login, password, seed = (os.environ.get(k, "") for k in ("CMUX_GITHUB_TEST_LOGIN", "CMUX_GITHUB_TEST_PASSWORD", "CMUX_GITHUB_TEST_TOTP_SEED"))
    if not all((login, password, seed)): return 1 if not record("GitHub credentials", False, "required probe secrets are absent") else 1
    deadline = time.monotonic() + 300; installed = False; last = ""
    while time.monotonic() < deadline and not installed:
        current = page(tab); last = current
        if current == "login":
            if not (fill(tab, "#login_field", login) and fill(tab, "#password", password) and click_text(tab, "^sign in$")): break
        elif current == "2fa":
            code2 = totp(seed); print("::add-mask::" + code2, flush=True)
            field = next((x for x in ("#app_totp", "#otp", "input[name=app_otp]", "input[name=otp]") if "yes" in js(tab, f"document.querySelector({json.dumps(x)})?'yes':'no'")), "")
            if not field or not fill(tab, field, code2) or not click_text(tab, "^verify"): break
        elif current == "device": break
        elif current == "authorize":
            if not click_text(tab, "^authorize"): break
        elif current == "sudo":
            if not (fill(tab, "#sudo_password", password) and click_text(tab, "^confirm")): break
        elif current == "install":
            if not click_text(tab, rf"^{re.escape(args.org)}\b|{re.escape(args.org)}$"): break
        elif current == "permissions":
            if not click_text(tab, "only select repositories"): break
            click_text(tab, "select repositories")
            time.sleep(1)
            field = next((x for x in ("#repository-menu-filter-field", "input[placeholder*='Search for a repository']", "input[aria-label*='repositor' i]") if "yes" in js(tab, f"document.querySelector({json.dumps(x)})?'yes':'no'")), "")
            if field: fill(tab, field, args.repo); time.sleep(2)
            if not click_text(tab, rf"(^|/){re.escape(args.repo)}$"): break
            if not click_text(tab, "^install$"): break
            installed = True
        elif current == "left": installed = True
        else: time.sleep(2)
        time.sleep(2)
    if not record("GitHub App installation", installed, f"last page={last}", shot("github-installed")): return 1
    token_file = HERE.parent / "cmux-next" / "dev-signin-token.py"
    spec = importlib.util.spec_from_file_location("signin", token_file); mod = importlib.util.module_from_spec(spec); assert spec.loader; spec.loader.exec_module(mod)
    email = os.environ.get("CMUX_UITEST_STACK_EMAIL") or os.environ.get("CMUX_DOGFOOD_STACK_EMAIL", "")
    pwd = os.environ.get("CMUX_UITEST_STACK_PASSWORD") or os.environ.get("CMUX_DOGFOOD_STACK_PASSWORD", "")
    if not email or not pwd: return 1 if not record("Stack readback credentials", False, "missing Stack credentials") else 1
    try: token = mod.sign_in(email, pwd)["accessToken"]
    except Exception as exc: return 1 if not record("Stack sign-in", False, exc) else 1
    status = repos = None
    for _ in range(30):
        s, body = api_get(token, "/v1/integrations/github/status")
        if s == 200 and (body.get("connection") or {}).get("status") == "active":
            rs, rb = api_get(token, "/v1/integrations/github/repos"); names = [x if isinstance(x, str) else x.get("full_name", "") for x in rb.get("repos", [])] if rs == 200 else []
            if any(str(x).lower() == REPO.lower() for x in names): status, repos = body, names; break
        time.sleep(4)
    ok = status is not None and repos is not None
    detail = f"active={bool(status)} repos={len(repos or [])} target={REPO}"
    final_shot = shot("repository-list")
    if not record("Repository list visible", ok, detail, final_shot): return 1
    return 0


def main() -> int:
    """Always leave scrubbed evidence so scheduled failures are diagnosable."""
    status = 1
    error = ""
    try:
        status = _run_probe()
    except Exception as exc:  # noqa: BLE001 - the evidence wrapper must survive probe failures
        error = scrub(exc)
        record("probe exception", False, error)
    finally:
        result = {"ok": status == 0 and not error,
                  "app": {"version": APP_META.get("CFBundleShortVersionString"),
                          "build": APP_META.get("CFBundleVersion"),
                          "commit": APP_META.get("CMUXCommit")},
                  "repo": REPO, "steps": steps,
                  "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        if error:
            result["error"] = error
        (OUT / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        (OUT / "summary.md").write_text("# Accounts NIGHTLY probe\n\n" +
                                        "\n".join(f"- {'PASS' if x['ok'] else 'FAIL'} **{x['step']}**: {x['detail']}" for x in steps) + "\n")
        print("ACCOUNTS_NIGHTLY_PROBE " + json.dumps(result, separators=(",", ":")), flush=True)
    return status


if __name__ == "__main__": raise SystemExit(main())
