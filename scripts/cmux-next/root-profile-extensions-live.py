#!/usr/bin/env python3
"""Live check: after a launch with no browser tab, no extension runs in Chromium's root profile (first-seconds bench,
2026-10-28).

Chromium's root `Default` profile is the one CEF starts for its global context; no cmux tab uses it. Through
`--load-extension` the built-in uBlock Origin loaded into every profile Chromium started, that one too: two
background pages, two extension renderers, every 49.5 MB filter-engine write done twice (step 92df0d13, Debug
v2.2.3). With the feature `chromiumAdBlockerAtFirstTab` on, a fork with `cmux_ext_load_command_line_async` loads it
into a profile only before that profile's first browser tab, and a fork without the call loads none (unless the
person turned `browser.builtInAdBlocker` on): either way the root profile runs no extension.

Launches the app (a Debug build of a development bundle: it opens a DevTools port through
CMUX_NEXT_CEF_EXTRA_SWITCHES), lets Chromium start and settle with no browser tab, then lists the DevTools targets.
Fails when any extension background page or service worker runs. Prints ROOT-PROFILE-EXT lines and `debug.cef`
`built_in_extensions` (the feature, the fork's call, the person's choice, the way taken).

  root-profile-extensions-live.py --app APP [--features chromiumAdBlockerAtFirstTab] [--settle 30] [--out DIR]

A run-it-yourself check on a fleet GUI host (the nx-remote or cmux-ci measurement step), never a CI job.
"""
import argparse
import json
import os
import shutil
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def note(text):
    print(text, flush=True)


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def extension_targets(targets):
    """The extension background pages and service workers among the DevTools targets."""
    return [t for t in targets if (t.get("url") or "").startswith("chrome-extension://")
            and t.get("type") in ("background_page", "service_worker")]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--features", default="chromiumAdBlockerAtFirstTab", help="CMUX_ENABLE_FEATURES for the launch")
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "artifacts", "root-profile-extensions"))
    opts, _ = parser.parse_known_args()
    os.makedirs(opts.out, exist_ok=True)
    from bench_launch import BenchApp
    from ext_e2e import cdp
    port = free_port()
    env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={port}:remote-allow-origins=*"}
    if opts.features:
        env["CMUX_ENABLE_FEATURES"] = opts.features
    app = BenchApp(opts.app, out=opts.out, env=env)
    report = {"app": opts.app, "features": opts.features, "ok": False}
    try:
        shutil.rmtree(os.path.join(os.path.expanduser("~"), "Library/Application Support/cmux/tags", app.tag, "tui"),
                      ignore_errors=True)
        app.launch()
        time.sleep(opts.settle)
        cef = app.rpc("debug.cef", timeout=10)
        report["cef_state"] = cef.get("state")
        report["built_in_extensions"] = cef.get("built_in_extensions")
        note("ROOT-PROFILE-EXT debug.cef " + json.dumps({"state": cef.get("state"),
                                                          "built_in_extensions": cef.get("built_in_extensions")}))
        targets = []
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                targets = cdp.target_infos(port)
                break
            except OSError:
                time.sleep(0.5)
        report["targets"] = [{k: t.get(k) for k in ("type", "url", "browserContextId")} for t in targets]
        running = extension_targets(targets)
        report["extensions"] = [{k: t.get(k) for k in ("type", "url", "browserContextId")} for t in running]
        contexts = sorted({t.get("browserContextId") for t in running})
        note("ROOT-PROFILE-EXT targets " + json.dumps({"targets": len(targets), "extension_workers": len(running),
                                                        "profiles": len(contexts)}))
        for t in running:
            note("ROOT-PROFILE-EXT running " + json.dumps({k: t.get(k) for k in ("type", "url", "browserContextId")}))
        report["ok"] = bool(targets) and not running
        note("ROOT-PROFILE-EXT " + ("PASS: no extension runs before the first browser tab, the root profile included"
                                    if report["ok"] else
                                    "FAIL: " + (f"{len(running)} extension background pages run in {len(contexts)} profiles "
                                                "with no browser tab (the root profile among them)" if running
                                                else "no DevTools targets read")))
    except Exception as error:  # noqa: BLE001 - the report keeps what was read
        report["error"] = f"{type(error).__name__}: {error}"[:400]
        note("ROOT-PROFILE-EXT ERROR " + report["error"])
    finally:
        app.stop()
        with open(os.path.join(opts.out, "report.json"), "w") as f:
            json.dump(report, f, indent=1)
    sys.exit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
