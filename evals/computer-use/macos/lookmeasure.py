# SPDX-License-Identifier: MIT
"""lookmeasure.py: what one look at a window costs the model, per arm (no model in the loop; the guest's model
endpoint only counts tokens).

  python3 lookmeasure.py --arm cmux-cu|aside|codex-cu --out DIR     (in a guest GUI session, through gr.sh)

For six apps (TextEdit document, Calculator, Safari on the harness page, Finder, System Settings, Notes), opened in
the background: the first look at the target window, a second look with nothing changed, as each arm's agent would
ask for them (cmux `get_ui_tree`, Aside `getAXState()` in its repl, Codex `get_app_state`). Each result's text is
counted in input tokens by the subrouter (`input_tokens` of a one-token reply, an empty prompt subtracted); images
are counted and sized but not converted to tokens.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import codex_arm  # noqa: E402  (registers aside and codex arms)
import aside_arm  # noqa: E402
import bgmatrix as bm  # noqa: E402

CFG = open(os.path.expanduser("~/.codex/config.toml")).read()
URL = os.environ.get("LOOK_URL") or re.search(r'base_url\s*=\s*"([^"]+)"', CFG).group(1)
TOK = re.search(r'experimental_bearer_token\s*=\s*"([^"]+)"', CFG).group(1)


def ask(s):
    body = json.dumps({"model": "gpt-6.1-sol", "store": False, "stream": True, "instructions": "Reply OK.",
                       "input": [{"role": "user", "content": [{"type": "input_text", "text": s}]}]}).encode()
    req = urllib.request.Request(URL + "/responses", body, {"Authorization": "Bearer " + TOK, "Content-Type": "application/json",
                                                           "X-Subrouter-Agent": "codex", "X-Subrouter-Client": "cu-bench-vm"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                raw = r.read().decode()
            found = [int(x) for x in re.findall(r'"input_tokens":\s*(\d+)', raw)]
            if found:
                return max(found)
        except Exception:  # noqa: BLE001
            time.sleep(2 + 3 * attempt)
    return None


BASE = None


def tokens(text):
    global BASE
    if BASE is None:
        BASE = ask(".")
    n = ask("." + "\n" + text)
    return None if n is None or BASE is None else n - BASE


APPS = [("textedit", "TextEdit", "obs-doc.txt"), ("calculator", "Calculator", "Calculator"), ("safari", "Safari", "CUEV Page"),
        ("finder", "Finder", "admin"), ("settings", "System Settings", ""), ("notes", "Notes", "Notes")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    doc = os.path.expanduser("~/obs-doc.txt")
    open(doc, "w").write("".join(f"line {i} the quick brown fox jumps over the lazy dog\n" for i in range(1, 41)))
    for cmd in (f"open -g -a TextEdit {doc}", "open -g -a Calculator", f"open -g -a Safari {os.path.expanduser('~/cu/page.html')}",
                f"open -g -a Finder {os.path.expanduser('~')}", "open -g -a 'System Settings'", "open -g -a Notes"):
        subprocess.run(cmd, shell=True)
    time.sleep(8)
    arm = bm.make_arm(a.arm, a.out)
    rows = []
    for key, app, title in APPS:
        aside_arm.CURRENT["app"] = app
        try:
            ws = arm.windows()
            w = next((x for x in ws if (title and x["title"].startswith(title)) or (not title and x.get("app") in ("System Settings", "com.apple.systempreferences"))), ws[0] if ws else None)
        except Exception as e:  # noqa: BLE001
            print("no window", key, e, flush=True)
            continue
        if w is None:
            print("no window", key, flush=True)
            continue
        if isinstance(arm, codex_arm.Codex):
            codex_arm.select_window(arm, w)
        for label in ("look1", "look2"):
            t0 = time.monotonic()
            if isinstance(arm, codex_arm.Codex):
                r = arm.call("get_app_state", {"app": arm.app_arg(app)})
            elif arm.id.startswith("aside"):
                var = arm.h(app)
                if label == "look1":
                    r = arm.repl(f"await {var}.getAXState({{ windowId: {json.dumps(w['aside_wid'])}, disableDiffing: true }});", title="look")
                else:
                    r = arm.repl(f"await {var}.getAXState();", title="look")
            else:
                r = arm.call("get_ui_tree", {"window_id": w["wid"]})
            ms = int((time.monotonic() - t0) * 1000)
            text = r.text()
            open(os.path.join(a.out, f"{key}-{label}.txt"), "w").write(text)
            imgs = [base64.b64decode(i["data"]) for i in r.images]
            row = {"arm": a.arm, "app": key, "look": label, "bytes": len(text.encode()), "tokens": tokens(text),
                   "images": len(imgs), "image_bytes": sum(len(b) for b in imgs),
                   "image_px": [aside_arm.img_size(b) for b in imgs], "ms": ms, "error": r.is_error}
            rows.append(row)
            print(json.dumps(row), flush=True)
    arm.close()
    json.dump(rows, open(os.path.join(a.out, "looks.json"), "w"), indent=1)
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
