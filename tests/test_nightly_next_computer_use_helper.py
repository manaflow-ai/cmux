#!/usr/bin/env python3
"""The cmux NEXT nightly ships the Computer Use helper that onboarding grants (cx-urd.6).

Onboarding and the legacy Computer Use driver only use a helper at
`Contents/Library/cmux Computer Use.app` (com.cmuxterm.cua) whose signature is
the team's Developer ID (CuaHelperIdentity, scripts/cmux-cua-helper-trust.sh).
An app without one offers no grant at all. So the nightly must:

- assemble the helper after the Release build (build-cmux-cua.sh --helper-app),
- check before signing that the helper is there with its identity and slices,
- check after signing that it passes the Developer ID requirement,
- and map its executable to its notices (bundle-map.json).

scripts/ci/verify-computer-use-helper.sh is that check; it runs on the app's
unsigned layout here (the signature half needs codesign and a real identity,
so CI runs it after the Codesign step).
"""

import json
import os
import plistlib
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NIGHTLY = os.path.join(ROOT, ".github", "workflows", "nightly.yml")
VERIFY = os.path.join(ROOT, "scripts", "ci", "verify-computer-use-helper.sh")
BUNDLE_MAP = os.path.join(ROOT, "scripts", "cmux-next", "notices", "bundle-map.json")
HELPER = "Contents/Library/cmux Computer Use.app"
FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def make_app(root, bundle_id="com.cmuxterm.cua", executable=True):
    app = os.path.join(root, "cmux.app")
    helper = os.path.join(app, HELPER)
    os.makedirs(os.path.join(helper, "Contents", "MacOS"))
    with open(os.path.join(helper, "Contents", "Info.plist"), "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "cmux-cua"}, handle)
    if executable:
        path = os.path.join(helper, "Contents", "MacOS", "cmux-cua")
        with open(path, "w") as handle:
            handle.write("#!/bin/sh\n")
        os.chmod(path, 0o755)
    return app


def verify(app):
    if not os.path.exists(VERIFY):
        return subprocess.CompletedProcess([VERIFY], 127, "", "missing verify-computer-use-helper.sh")
    return subprocess.run(["bash", VERIFY, "layout", app], capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        result = verify(make_app(tmp))
        _check(result.returncode == 0, f"a helper with its identity and executable passes ({result.stderr.strip()})")
    with tempfile.TemporaryDirectory() as tmp:
        app = os.path.join(tmp, "cmux.app")
        os.makedirs(os.path.join(app, "Contents"))
        result = verify(app)
        _check(result.returncode != 0 and "cmux Computer Use.app" in result.stderr,
               f"an app without the helper fails, naming it ({result.stderr.strip()})")
    with tempfile.TemporaryDirectory() as tmp:
        result = verify(make_app(tmp, bundle_id="com.cmuxterm.cua.dev"))
        _check(result.returncode != 0 and "com.cmuxterm.cua" in result.stderr,
               f"a helper with another bundle id fails ({result.stderr.strip()})")
    with tempfile.TemporaryDirectory() as tmp:
        result = verify(make_app(tmp, executable=False))
        _check(result.returncode != 0, f"a helper without its executable fails ({result.stderr.strip()})")

    workflow = yaml.safe_load(open(NIGHTLY, encoding="utf-8"))
    build = "\n".join(str(s.get("run", "")) for s in workflow["jobs"]["build-nightly-app"]["steps"])
    _check("build-cmux-cua.sh" in build and "--helper-app" in build,
           "the nightly app build assembles the helper (build-cmux-cua.sh --helper-app)")
    _check("verify-computer-use-helper.sh layout" in build, "the app build checks the helper before upload")
    sign_steps = workflow["jobs"]["build-sign-notarize-nightly"]["steps"]
    names = [s.get("name", "") for s in sign_steps]
    runs = [str(s.get("run", "")) for s in sign_steps]
    codesign = names.index("Codesign apps") if "Codesign apps" in names else -1
    signed = [i for i, run in enumerate(runs) if "verify-computer-use-helper.sh signed" in run]
    _check(codesign >= 0 and any(i > codesign for i in signed),
           "after Codesign apps, the nightly checks the helper's Developer ID signature")
    # The helper's own notary submission starts before Codesign apps, so Apple's
    # wait overlaps the smoke steps, and the DMG step only finishes it, with a
    # bounded wait: an unbounded one ran past the step timeout before the
    # pending-DMG state existed, which left nothing to recover.
    started = [i for i, run in enumerate(runs) if "notarize-computer-use-helper.sh --start" in run]
    _check(codesign >= 0 and any(i < codesign for i in started),
           "the helper's notary submission starts before Codesign apps")
    _check(codesign >= 0 and "all-except-computer-use" in runs[codesign],
           "Codesign apps keeps the submitted helper's signature (all-except-computer-use)")
    notarize = next((s for s in sign_steps if s.get("id") == "notarize-nightly"), {})
    env = notarize.get("env", {})
    _check("CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE" in env and "CMUX_COMPUTER_USE_NOTARY_WAIT_TIMEOUT" in env,
           "the DMG step finishes the started helper submission with a bounded wait")
    helper_script = open(os.path.join(ROOT, "scripts", "ci", "notarize-computer-use-helper.sh"), encoding="utf-8").read()
    _check("CMUX_COMPUTER_USE_NOTARY_WAIT_TIMEOUT" in helper_script,
           "notarize-computer-use-helper.sh bounds its notarytool wait")
    # The architecture gate runs in both preparation legs (primary and fallback), before signing (#21024).
    for prepare_job in ("prepare-nightly-variant-primary", "prepare-nightly-variant-fallback"):
        prepare_steps = workflow["jobs"][prepare_job]["steps"]
        arch_step = next((str(s.get("run", "")) for s in prepare_steps if s.get("name") == "Verify nightly binary architectures"), "")
        _check("cmux Computer Use.app/Contents/MacOS/cmux-cua" in arch_step,
               f"the architecture gate in {prepare_job} covers the helper's executable")

    entries = json.load(open(BUNDLE_MAP, encoding="utf-8"))["entries"]
    helper_entry = next((e for e in entries if e["path"] == f"{HELPER}/Contents/MacOS/cmux-cua"), None)
    _check(helper_entry is not None and "section:rust-cmux-cua" in helper_entry["notices"],
           "bundle-map.json maps the helper's executable to its Rust notices")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: the cmux NEXT nightly assembles, checks and maps the Computer Use helper")
    return 0


if __name__ == "__main__":
    sys.exit(main())
