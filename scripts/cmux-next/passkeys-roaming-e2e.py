#!/usr/bin/env python3
"""Roaming passkeys on a real relying party (cx-d0d.97, plans/cmux-next/passkeys.md 3.8 and 11).

Lawrence 2026-10-14: "ensure we support passkey sign in with bluetooth and security key like
yubikey". In a running cmux-next DEV app's CEF tab, on https://webauthn.io:

1. For each roaming transport (USB CTAP2, USB U2F, NFC, BLE, hybrid "cable"): a DevTools virtual
   authenticator of that transport (`debug.cef.devtools`, Debug builds), Register with attachment
   Cross-Platform, then Authenticate with the username filled (an allow list). PASS when webauthn.io
   shows its success alert after Register and opens /profile after Authenticate (both verified by
   its server), and, when CEF returns the authenticator id, the authenticator holds one credential
   whose sign count went up. CEF usually loses that reply: then the row says so, and the pass
   proves the request path through a virtual authenticator (UI off), not the transport itself.
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
       [--real [--real-seconds 120] [--discoverable discouraged]]
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
parser.add_argument("--typing", action="store_true", help="also type into the page with trusted key events (engine smoke)")
parser.add_argument("--real", action="store_true", help="a real key or phone and a person; no virtual authenticator")
parser.add_argument("--real-seconds", type=int, default=120, help="--real: how long each step waits for the person")
parser.add_argument("--hybrid-only", action="store_true", help="--real: only the phone step")
parser.add_argument("--hybrid", action="store_true", help="--real: after the key, register and sign in with a phone (QR + Bluetooth)")
parser.add_argument("--discoverable", default="", choices=["", "discouraged", "preferred", "required"],
                    help="webauthn.io Discoverable Credential; `discouraged` needs only a touch on a key with no PIN")
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
        if not isinstance(reply, dict):
            return {"error": f"not an object: {str(reply)[:80]}"}
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
    reply = rpc("browser.page.eval", {"tab": tab, "script": script})
    if not isinstance(reply, dict):
        return {"__error": f"reply {reply!r}"}
    return reply.get("value") if "error" not in reply else {"__error": reply.get("error")}


def devtools(method, params=None):
    reply = rpc("debug.cef.devtools", {"method": method, "params": params or {}})
    if not isinstance(reply, dict):
        return {"__error": f"reply {reply!r}"}
    if reply.get("error"):
        return {"__error": reply["error"]}
    try:
        return json.loads(reply.get("result") or "{}")
    except ValueError:
        return {"raw": reply.get("result")}


def shot(name):
    """The app's windows (JSON, every layer) and two pictures: the composed window with its
    popups and dialogs, and the frontmost window alone."""
    if not (opts.capture and opts.pid):
        return None
    base = os.path.join(opts.out, name)
    def helper(*args):
        try:
            return subprocess.run(["bash", opts.capture, *args], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as error:
            return subprocess.CompletedProcess(args, 1, "", str(error))
    listed = helper("windows", "--all-layers", "--pid", str(opts.pid))
    with open(base + ".windows.json", "w") as handle:
        handle.write(listed.stdout)
    notes = []
    for suffix, extra in (("", ["--with-popups"]), (".front", [])):
        done = helper("shot", "--pid", str(opts.pid), *extra, "--out", f"{base}{suffix}.png")
        notes.append(f"{base}{suffix}.png" if done.returncode == 0 else f"capture failed: {done.stderr.strip()[:160]}")
    return {"pictures": notes, "windows": window_summary(listed.stdout)}


def window_summary(text):
    """(layer, title, size) per on-screen window: a WebAuthn sheet is its own window of the app."""
    try:
        data = json.loads(text)
    except ValueError:
        return text.strip()[:200]
    windows = data.get("windows", data) if isinstance(data, dict) else data
    rows = []
    for w in windows if isinstance(windows, list) else []:
        if not isinstance(w, dict):
            continue
        b = w.get("bounds") if isinstance(w.get("bounds"), dict) else {}
        rows.append([w.get("layer", w.get("z_index")), w.get("title", ""), int(b.get("width") or 0), int(b.get("height") or 0)])
    return rows


def row(name, status, detail):
    ROWS.append({"check": name, "status": status, "detail": detail})
    print(f"{status} | {name:28} | {str(detail)[:300]}", flush=True)


def page_ready(tab):
    return js(tab, "!!document.getElementById('register-button') && !!window.Alpine && document.readyState === 'complete'") is True


def load_site(tab):
    js(tab, f"location.href = {json.dumps(opts.site + '/')}")
    time.sleep(1)  # test harness: the old document goes away before the ready check
    return wait(lambda: page_ready(tab), 45)


def fill(tab, username, attachment, discoverable=""):
    """Alpine's x-model reads input/change events; the buttons' @click handlers run on click().
    Returns the attachment the page now has, or "" when the discoverable choice did not take."""
    return js(tab, "(() => { const u = document.getElementById('input-email');"
                   f" u.value = {json.dumps(username)}; u.dispatchEvent(new Event('input', {{bubbles: true}}));"
                   f" const d = {json.dumps(discoverable)};"
                   " if (d) { const s = document.getElementById('discoverableCredential');"
                   " s.value = d; s.dispatchEvent(new Event('change', {bubbles: true})); if (s.value !== d) return ''; }"
                   " const a = document.getElementById('attachment');"
                   f" a.value = {json.dumps(attachment)}; a.dispatchEvent(new Event('change', {{bubbles: true}}));"
                   " return a.value; })()")


def alert_text(tab):
    value = js(tab, "(() => { const a = document.querySelector('.alert'); return a ? a.textContent.trim() : ''; })()")
    return value if isinstance(value, str) else ""


def alert_kind(tab):
    """'success' or 'error' from webauthn.io's alert class (showSuccessAlert / showErrorAlert), else ''."""
    value = js(tab, "(() => { const a = document.querySelector('.alert'); return a ? a.className : ''; })()")
    value = value if isinstance(value, str) else ""
    return "success" if "alert-success" in value else "error" if "alert-danger" in value else ""


def on_profile(tab):
    return js(tab, "location.pathname") == "/profile"


def click(tab, element_id):
    return js(tab, f"(() => {{ document.getElementById({json.dumps(element_id)}).click(); return 'clicked'; }})()")


def credentials(authenticator):
    reply = devtools("WebAuthn.getCredentials", {"authenticatorId": authenticator})
    return reply.get("credentials") if isinstance(reply.get("credentials"), list) else None


def ceremony(tab, transport):
    if not load_site(tab):
        return "FAIL", f"{opts.site} did not load: {js(tab, 'location.href')}"
    enabled = devtools("WebAuthn.enable", {"enableUI": False})
    if "__error" in enabled and "timedOut" not in str(enabled):
        return "FAIL", f"WebAuthn.enable: {enabled}"
    added = devtools("WebAuthn.addVirtualAuthenticator",
                     {"options": {"automaticPresenceSimulation": True, **AUTHENTICATORS[transport]}})
    # CEF's in-process DevTools loses this reply (timedOut after 5 s) while the call itself
    # runs (passkeys.md 10 and 11). Only that error counts as "added"; any other error fails.
    authenticator = added.get("authenticatorId")
    if not authenticator and not ("timedOut" in str(added) and "addVirtualAuthenticator" in str(added)):
        devtools("WebAuthn.disable")
        return "FAIL", f"no virtual authenticator: {added}"
    note = "" if authenticator else "id lost, transport and sign count not read; "
    try:
        username = f"cmux-{transport}-{uuid.uuid4().hex[:8]}"
        chosen = fill(tab, username, "cross_platform")
        if chosen != "cross_platform":
            return "FAIL", f"attachment not set: {chosen!r}"
        click(tab, "register-button")
        kind = wait(lambda: alert_kind(tab), 30)
        made = credentials(authenticator) if authenticator else []
        if kind != "success" or (authenticator and (made is None or len(made) != 1)):
            return "FAIL", note + f"register: {kind or 'no result'} {alert_text(tab)!r}, credentials {made}"
        count = made[0].get("signCount", 0) if made else None
        click(tab, "login-button")
        signed = wait(lambda: on_profile(tab) or alert_kind(tab) == "error", 30)
        arrived = signed is True or on_profile(tab)
        after = credentials(authenticator) if authenticator else []
        counted = not authenticator or (after is not None and len(after) == 1 and after[0].get("signCount", 0) > (count or 0))
        if not arrived or not counted:
            return "FAIL", note + f"sign in: profile {arrived}, alert {alert_text(tab)!r}, sign count {count} -> {after}"
        picture = shot(f"signed-in-{transport}")
        counts = f"sign count {count} -> {after[0].get('signCount')}" if after else "sign count not read"
        return "PASS", note + f"{username}: registered and signed in (/profile), {counts}; {picture}"
    finally:
        devtools("WebAuthn.disable")  # drops every virtual authenticator, one whose id was lost too


def dialogs(tab):
    """Chromium's dialog in the pane: recorded and captured, a person judges the picture."""
    row("dialog: none (baseline)", "NOTE", shot("dialog-baseline"))
    # 1. A virtual USB key that is never touched: Chromium's "use your security key" sheet.
    if load_site(tab):
        devtools("WebAuthn.enable", {"enableUI": True})
        added = devtools("WebAuthn.addVirtualAuthenticator",
                         {"options": {**AUTHENTICATORS["usb"], "automaticPresenceSimulation": False}})
        fill(tab, f"cmux-touch-{uuid.uuid4().hex[:8]}", "cross_platform")
        click(tab, "register-button")
        time.sleep(4)  # test harness: the sheet animates in
        row("dialog: touch your key", "NOTE", {"authenticator": str(added)[:80], "focused": js(tab, "document.hasFocus()"),
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
    try:
        subprocess.run(["say", text], timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        pass


def real_key(tab, username, discoverable, prompts, label):
    """A real security key or phone, no virtual authenticator: a person touches the key or scans
    the QR code with a phone. Pictures every 3 s while a sheet is up."""
    # A signed-in webauthn.io session sends the next visit to /profile: start signed out
    # (a DEV tag's throwaway profile; Network.clearBrowserCookies clears all of its cookies).
    devtools("Network.clearBrowserCookies")
    if not load_site(tab) or js(tab, "location.pathname") != "/":
        return "FAIL", f"{opts.site} did not load signed out: {js(tab, 'location.href')}"
    devtools("WebAuthn.disable")
    steps = []
    for step, button, done, prompt in (
        ("register", "register-button", lambda: alert_kind(tab) != "", prompts[0]),
        ("sign-in", "login-button", lambda: on_profile(tab) or alert_kind(tab) == "error", prompts[1]),
    ):
        if step == "register" and fill(tab, username, "cross_platform", discoverable) != "cross_platform":
            return "FAIL", "attachment not set to Cross-Platform"
        click(tab, button)
        say(prompt)
        began, index = time.time(), 0
        while time.time() - began < opts.real_seconds and not done():
            if index % 3 == 0:
                shot(f"real-{label}-{step}-{index:03d}")
            index += 1
            time.sleep(1)  # test harness: a person acts at their own pace
        passed = alert_kind(tab) == "success" if step == "register" else on_profile(tab)
        steps.append(f"{step}: {'pass' if passed else 'fail'} {alert_text(tab) or js(tab, 'location.pathname')!r} after {time.time() - began:.0f} s")
        shot(f"real-{label}-{step}-done")
        if not passed:
            say(f"The {label} test failed.")
            return "FAIL", f"{username}: " + "; ".join(steps)
    say(f"The {label} test passed.")
    return "PASS", f"{username}: " + "; ".join(steps)


def typing(tab):
    """Trusted key events (Input.dispatchKeyEvent) into webauthn.io's username field."""
    if not load_site(tab):
        return "FAIL", "page did not load"
    js(tab, "(() => { const u = document.getElementById('input-email'); u.value = ''; u.focus(); return document.activeElement === u; })()")
    text = "cmux typing 123"
    for ch in text:
        devtools("Input.dispatchKeyEvent", {"type": "keyDown", "text": ch, "key": ch, "unmodifiedText": ch})
        devtools("Input.dispatchKeyEvent", {"type": "keyUp", "key": ch})
    devtools("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8})
    devtools("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8})
    value = js(tab, "document.getElementById('input-email').value")
    return ("PASS" if value == text[:-1] else "FAIL"), f"field value {value!r} (expected {text[:-1]!r})"


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
        if opts.typing:
            status, detail = typing(tab)
            row("typing (trusted key events)", status, detail)
        if opts.real and not opts.hybrid_only:
            status, detail = real_key(tab, f"cmux-key-{uuid.uuid4().hex[:8]}", opts.discoverable, (
                "Passkey test. Touch the security key now. If a PIN box appears, press Cancel.",
                "Touch the security key again to sign in."), "security key")
            row("webauthn.io real key", status, detail)
        if opts.real and (opts.hybrid or opts.hybrid_only):
            status, detail = real_key(tab, f"cmux-phone-{uuid.uuid4().hex[:8]}", "", (
                "Phone test. Please unplug the security key. In the cmux sheet choose iPhone, iPad, or Android device. Scan the QR code"
                " with the phone camera and approve on the phone. If the Mac asks to use Bluetooth, click Allow.",
                "Sign in with the phone. Choose the phone in the sheet, scan the QR code again and approve."), "phone")
            row("webauthn.io real phone (hybrid)", status, detail)
        if opts.real:
            say("All passkey steps are done. Thank you.")
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
