#!/usr/bin/env python3
"""Roaming passkeys on a real relying party (cx-d0d.97, plans/cmux-next/passkeys.md 3.8 and 11).

Lawrence 2026-10-14: "ensure we support passkey sign in with bluetooth and security key like
yubikey". In a running cmux-next DEV app's CEF tab, on https://webauthn.io:

1. For each roaming transport (USB CTAP2, USB U2F, NFC, BLE, hybrid "cable"): a DevTools virtual
   authenticator of that transport (`debug.cef.devtools`, Debug builds), Register with attachment
   Cross-Platform, then Authenticate with the username filled (an allow list). PASS when webauthn.io
   says "Success!" after Register, opens /profile after Authenticate, and the authenticator holds
   one credential whose sign count went up.
2. Chromium's own WebAuthn dialog in the pane (record + screenshot, not judged): the
   "touch your security key" sheet (virtual USB key, UI on, no automatic touch), and the sheet a
   real cross-platform request shows with no virtual authenticator (hybrid QR / Bluetooth / USB).

Real PIN entry, a real touch and a real phone need a person (checklist.md).

The script attaches to the app through its socket and never launches or quits it. Screenshots
go through the capture helper when --capture and --pid are given (nx-remote: $NX_CAPTURE).

`--real` (a person at the Mac, real key or phone): Register and Authenticate with no virtual
authenticator; `say` tells the person when to touch the key or type the PIN; a picture every 3 s.

Usage: passkeys-roaming-e2e.py --socket SOCK [--pid PID --capture HELPER] [--out DIR]
       [--transports usb,usb-u2f,nfc,ble,cable] [--site https://webauthn.io] [--no-dialogs]
       [--real [--real-seconds 120]]
Writes roaming.json to --out. Exit 0 when every judged transport passes.
"""
import argparse, json, os, socket, subprocess, sys, time, uuid

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--pid", type=int, default=0)
parser.add_argument("--capture", default="")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--transports", default="usb,usb-u2f,nfc,ble,cable")
parser.add_argument("--site", default="https://webauthn.io")
parser.add_argument("--no-dialogs", action="store_true")
parser.add_argument("--real", action="store_true", help="a real key or phone and a person; no virtual authenticator")
parser.add_argument("--real-seconds", type=int, default=120, help="--real: how long each step waits for the person")
opts = parser.parse_args()

AUTHENTICATORS = {
    # A YubiKey 5 over USB: CTAP 2.1, discoverable credentials, user verification (its PIN).
    "usb": {"protocol": "ctap2", "ctap2Version": "ctap2_1", "transport": "usb", "hasResidentKey": True,
            "hasUserVerification": True, "isUserVerified": True},
    # An older U2F-only key (YubiKey NEO, Security Key by Yubico gen 1).
    "usb-u2f": {"protocol": "u2f", "transport": "usb", "hasResidentKey": False, "hasUserVerification": False},
    "nfc": {"protocol": "ctap2", "transport": "nfc", "hasResidentKey": True, "hasUserVerification": True, "isUserVerified": True},
    "ble": {"protocol": "ctap2", "transport": "ble", "hasResidentKey": True, "hasUserVerification": True, "isUserVerified": True},
    # Hybrid (caBLE v2): the phone a person scans the QR code with.
    "cable": {"protocol": "ctap2", "transport": "cable", "hasResidentKey": True, "hasUserVerification": True, "isUserVerified": True},
}
ROWS = []


def rpc(method, params=None, timeout=40):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def run(action, args=None):
    return rpc("action.run", {"action": action, "args": args or {}, "focus": True, "confirm": True})


def js(tab, script):
    reply = rpc("browser.page.eval", {"tab": tab, "script": script}) or {}
    return reply.get("value") if "error" not in reply else {"__error": reply.get("error")}


def devtools(method, params=None):
    reply = rpc("debug.cef.devtools", {"method": method, "params": params or {}}) or {}
    if reply.get("error"):
        return {"__error": reply["error"]}
    try:
        return json.loads(reply.get("result") or "{}")
    except ValueError:
        return {"raw": reply.get("result")}


def shot(name):
    if not (opts.capture and opts.pid):
        return None
    path = os.path.join(opts.out, f"{name}.png")
    done = subprocess.run(["bash", opts.capture, "shot", "--pid", str(opts.pid), "--with-popups", "--out", path],
                          capture_output=True, text=True, timeout=60)
    return path if done.returncode == 0 else f"capture failed: {done.stderr.strip()[:200]}"


def row(name, status, detail):
    ROWS.append({"check": name, "status": status, "detail": detail})
    print(f"{status} | {name:28} | {str(detail)[:300]}", flush=True)


def page_ready(tab):
    return js(tab, "!!document.getElementById('register-button') && !!window.Alpine && document.readyState === 'complete'") is True


def load_site(tab):
    js(tab, f"location.href = {json.dumps(opts.site + '/')}")
    time.sleep(1)  # test harness: the old document goes away before the ready check
    return wait(lambda: page_ready(tab), 45)


def fill(tab, username, attachment):
    """Alpine's x-model reads input/change events; the buttons' @click handlers run on click()."""
    return js(tab, "(() => { const u = document.getElementById('input-email');"
                   f" u.value = {json.dumps(username)}; u.dispatchEvent(new Event('input', {{bubbles: true}}));"
                   " const a = document.getElementById('attachment');"
                   f" a.value = {json.dumps(attachment)}; a.dispatchEvent(new Event('change', {{bubbles: true}}));"
                   " return a.value; })()")


def alert_text(tab):
    value = js(tab, "(() => { const a = document.querySelector('.alert'); return a ? a.textContent.trim() : ''; })()")
    return value if isinstance(value, str) else ""


def click(tab, element_id):
    return js(tab, f"(() => {{ document.getElementById({json.dumps(element_id)}).click(); return 'clicked'; }})()")


def credentials(authenticator):
    reply = devtools("WebAuthn.getCredentials", {"authenticatorId": authenticator})
    return reply.get("credentials") if isinstance(reply.get("credentials"), list) else None


def ceremony(tab, transport):
    if not load_site(tab):
        return "FAIL", f"{opts.site} did not load: {js(tab, 'location.href')}"
    devtools("WebAuthn.enable", {"enableUI": False})
    added = devtools("WebAuthn.addVirtualAuthenticator",
                     {"options": {"automaticPresenceSimulation": True, **AUTHENTICATORS[transport]}})
    authenticator = added.get("authenticatorId")
    if not authenticator:
        devtools("WebAuthn.disable")
        return "FAIL", f"no virtual authenticator: {added}"
    try:
        username = f"cmux-{transport}-{uuid.uuid4().hex[:8]}"
        fill(tab, username, "cross_platform")
        click(tab, "register-button")
        registered = wait(lambda: (lambda t: t if ("Success" in t or "failed" in t.lower() or "error" in t.lower()) else None)(alert_text(tab)), 30)
        made = credentials(authenticator) or []
        if not registered or "Success" not in registered or len(made) != 1:
            return "FAIL", f"register: alert {registered!r}, credentials {len(made)}"
        count = made[0].get("signCount", 0)
        click(tab, "login-button")
        signed = wait(lambda: js(tab, "location.pathname") == "/profile" or (lambda t: t if "failed" in t.lower() else None)(alert_text(tab)), 30)
        path = js(tab, "location.pathname")
        after = credentials(authenticator) or []
        if path != "/profile" or len(after) != 1 or after[0].get("signCount", 0) <= count:
            return "FAIL", f"sign in: path {path!r}, alert {alert_text(tab)!r}, sign count {count} -> {[c.get('signCount') for c in after]}"
        picture = shot(f"signed-in-{transport}")
        return "PASS", f"{username}: registered and signed in (/profile), sign count {count} -> {after[0].get('signCount')}; {picture}"
    finally:
        devtools("WebAuthn.removeVirtualAuthenticator", {"authenticatorId": authenticator})
        devtools("WebAuthn.disable")


def dialogs(tab):
    """Chromium's dialog in the pane: recorded and captured, a person judges the picture."""
    # 1. A virtual USB key that is never touched: Chromium's "use your security key" sheet.
    if load_site(tab):
        devtools("WebAuthn.enable", {"enableUI": True})
        added = devtools("WebAuthn.addVirtualAuthenticator",
                         {"options": {**AUTHENTICATORS["usb"], "automaticPresenceSimulation": False}})
        fill(tab, f"cmux-touch-{uuid.uuid4().hex[:8]}", "cross_platform")
        click(tab, "register-button")
        time.sleep(4)  # test harness: the sheet animates in
        row("dialog: touch your key", "NOTE", {"authenticator": added.get("authenticatorId"), "focused": js(tab, "document.hasFocus()"),
                                               "alert": alert_text(tab), "screenshot": shot("dialog-touch-security-key")})
        devtools("WebAuthn.disable")
    # 2. A real cross-platform request (no virtual authenticator): hybrid QR, Bluetooth, USB.
    if load_site(tab):
        devtools("WebAuthn.disable")
        fill(tab, f"cmux-real-{uuid.uuid4().hex[:8]}", "cross_platform")
        click(tab, "register-button")
        time.sleep(5)  # test harness: Chromium enumerates transports and shows its first sheet
        row("dialog: real cross-platform", "NOTE", {"focused": js(tab, "document.hasFocus()"), "alert": alert_text(tab),
                                                    "screenshot": shot("dialog-real-cross-platform")})
    # Leaving the page cancels the pending request and closes the sheet.
    load_site(tab)


def say(text):
    """`--real` only: the person at the Mac hears what to do (macOS `say`)."""
    print(f"SAY {text}", flush=True)
    subprocess.run(["say", text], timeout=30)


def real_key(tab):
    """A real security key or phone, no virtual authenticator: a person touches the key, types
    the PIN in Chromium's dialog, or scans the QR code. Pictures every 3 s while a sheet is up."""
    if not load_site(tab):
        return "FAIL", f"{opts.site} did not load"
    devtools("WebAuthn.disable")
    username = f"cmux-real-{uuid.uuid4().hex[:8]}"
    steps = []
    for step, button, done, prompt in (
        ("register", "register-button", lambda: "Success" in alert_text(tab) or "failed" in alert_text(tab).lower(),
         "Passkey test. Touch the security key now. If cmux asks for a PIN, type the PIN and press return."),
        ("sign-in", "login-button", lambda: js(tab, "location.pathname") == "/profile" or "failed" in alert_text(tab).lower(),
         "Touch the security key again to sign in. Type the PIN if cmux asks."),
    ):
        if step == "register":
            fill(tab, username, "cross_platform")
        click(tab, button)
        say(prompt)
        began, index = time.time(), 0
        while time.time() - began < opts.real_seconds and not done():
            if index % 3 == 0:
                shot(f"real-{step}-{index:03d}")
            index += 1
            time.sleep(1)  # test harness: a person acts at their own pace
        result = alert_text(tab) or js(tab, "location.pathname")
        steps.append(f"{step}: {result!r} after {time.time() - began:.0f} s")
        shot(f"real-{step}-done")
        if not done() or "failed" in str(result).lower():
            say("The passkey test failed. Thank you.")
            return "FAIL", f"{username}: " + "; ".join(steps)
    say("The passkey test passed. Thank you.")
    return "PASS", f"{username}: " + "; ".join(steps)


def main():
    os.makedirs(opts.out, exist_ok=True)
    if not wait(lambda: "error" not in (rpc("system.identify") or {"error": 1}), 90):
        sys.exit("the app does not answer")
    run("palette.closeOtherWorkspaces")
    opened = wait(lambda: (lambda r: r if (r or {}).get("created") else None)(run("openBrowser", {"url": opts.site + "/", "engine": "cef"})), 90, 3)
    created = (opened or {}).get("created") or []
    tab = created[0] if created else None
    if not tab or not wait(lambda: page_ready(tab), 60, 1):
        row("(setup)", "FAIL", f"{opts.site} did not load in a CEF tab: {opened}")
    else:
        row("probe", "NOTE", js(tab, "JSON.stringify({ua: navigator.userAgent, secure: isSecureContext, focused: document.hasFocus()})"))
        if opts.real:
            status, detail = real_key(tab)
            row("webauthn.io real key", status, detail)
            opts.transports, opts.no_dialogs = "", True
        for transport in [t for t in opts.transports.split(",") if t]:
            status, detail = ceremony(tab, transport)
            row(f"webauthn.io {transport}", status, detail)
        if not opts.no_dialogs:
            dialogs(tab)
    with open(os.path.join(opts.out, "roaming.json"), "w") as handle:
        json.dump(ROWS, handle, indent=1)
    judged = [r for r in ROWS if r["status"] in ("PASS", "FAIL")]
    passed = sum(r["status"] == "PASS" for r in judged)
    print(f"RESULT {passed}/{len(judged)}", flush=True)
    return 0 if judged and passed == len(judged) else 1


if __name__ == "__main__":
    sys.exit(main())
