#!/usr/bin/env python3
"""Records the small real xctrace exports that trace.py's self-test parses (`check_real_xctrace_exports`).

Run it on a fleet Mac with Xcode (never on Lawrence's laptop). It compiles a tiny emitter, records it with
`xctrace record --launch` twice (Time Profiler with os_signpost; System Trace), exports the TOC and the three
tables trace.py reads (time-profile, os-signpost, syscall), strips personal data and writes them to
OUT/xcode-<major>/ with a fixture.json that says what the emitter did. Copy that folder into
scripts/cmux-next/tests/trace-fixtures/ to check it in.

The emitter is the shape trace.py must parse: 20 rounds of a `action.perform` interval (subsystem
com.cmuxterm.app.next, category action, the always-on message format) around 20 ms of main-thread CPU in a
function named `fixtureSpin`, then a 5 ms `usleep` (a system call of 1 ms or more, off CPU).

Scrubbing: user folders (`/Users/<name>` becomes `/Users/user`), the device name, the host name and the
user name are replaced; the file must then hold none of them, or the run fails. Each file must be under
MAX_BYTES (a fixture that grows means the recording caught more than the emitter).

  python3 scripts/cmux-next/trace_fixtures.py OUT
"""
import json, os, pwd, re, shutil, socket, subprocess, sys, tempfile

MAX_BYTES = 4_000_000
EMITTER = r'''
import Foundation
import os

let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "action")
var sink = 0.0

@inline(never) func fixtureSpin(_ milliseconds: Double) {
    let end = Date().addingTimeInterval(milliseconds / 1000)
    var x = 1.0
    while Date() < end { x = sin(x) + 1.0001 }
    sink += x
}

// System Trace starts its kernel tracing after the launch: a 2 s run recorded no syscall row (Xcode 26.6).
Thread.sleep(forTimeInterval: 3)
for _ in 0..<20 {
    let state = signposter.beginInterval("action.perform", id: signposter.makeSignpostID(),
                                         "id=fixture.spin origin=user input_age_ms=1.00")
    fixtureSpin(20)
    signposter.endInterval("action.perform", state)
    usleep(5_000)
}
print(sink > 0 ? "done" : "?")
'''
TABLES = {"profile": ["time-profile", "os-signpost"], "system": ["syscall"]}


def run(command, **kwargs):
    done = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if done.returncode != 0:
        raise SystemExit(f"trace_fixtures: {' '.join(command[:4])} exited {done.returncode}: {(done.stdout + done.stderr)[-800:]}")
    return done.stdout


def scrub(text, secrets):
    """Replaces user folders, the step's temp folder and each secret as a whole word only: the fleet account is
    `cmux`, and a plain replace turned the subsystem com.cmuxterm.app.next into com.userterm.app.next."""
    text = re.sub(r"/Users/[^/\"'<>\s]+", "/Users/user", text)
    text = re.sub(r"/tmp/[^/\"'<>\s]+/trace-fixtures-[A-Za-z0-9_]+/", "/tmp/trace-fixtures/", text)
    for secret, replacement in secrets:
        if secret:
            text = re.sub(rf"(?<![A-Za-z0-9_.-]){re.escape(secret)}(?![A-Za-z0-9_-])", replacement, text)
    return text


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    out = os.path.abspath(sys.argv[1])
    version = run(["xcrun", "xctrace", "version"]).strip()
    # The folder is named by Xcode's major: xctrace's own version number is not Xcode's (Xcode 26.5 ships
    # "xctrace version 16.0 (17F113)", Xcode 26.0 "26.0 (17C529)").
    xcode = run(["xcrun", "xcodebuild", "-version"]).splitlines()[0].strip()
    major = re.search(r"Xcode (\d+)", xcode).group(1)
    macos = run(["sw_vers", "-productVersion"]).strip()
    target = os.path.join(out, f"xcode-{major}")
    os.makedirs(target, exist_ok=True)
    work = tempfile.mkdtemp(prefix="trace-fixtures-")
    source = os.path.join(work, "emitter.swift")
    binary = os.path.join(work, "fixture-emitter")
    with open(source, "w") as f:
        f.write(EMITTER)
    run(["xcrun", "swiftc", "-O", source, "-o", binary], timeout=600)
    device = None
    user = pwd.getpwuid(os.getuid()).pw_name
    host = socket.gethostname()
    exported = {}
    for name, template in (("profile", "Time Profiler"), ("system", "System Trace")):
        trace = os.path.join(work, f"{name}.trace")
        command = ["xcrun", "xctrace", "record", "--template", template, "--output", trace, "--no-prompt",
                   "--time-limit", "30s"]
        if name == "profile":
            command += ["--instrument", "os_signpost"]
        run(command + ["--launch", "--", binary], timeout=600)
        toc_xml = run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], timeout=300)
        match = re.search(r'<device [^>]*name="([^"]*)"', toc_xml)
        device = device or (match.group(1) if match else None)
        exported[f"{name}-toc"] = toc_xml
        for schema in TABLES[name]:
            path = os.path.join(work, f"{schema}.xml")
            run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                 f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]', "--output", path], timeout=600)
            exported[schema] = open(path, errors="replace").read()
    secrets = [(device, "Fleet Mac"), (host, "fleet-host"), (user, "user")]
    for name, text in exported.items():
        text = scrub(text, secrets)
        leaked = [s for s, _ in secrets
                  if s and len(s) > 2 and re.search(rf"(?<![A-Za-z0-9_.-]){re.escape(s)}(?![A-Za-z0-9_-])", text)]
        if leaked:
            raise SystemExit(f"trace_fixtures: {name} still holds {leaked} after scrubbing")
        if len(text.encode()) > MAX_BYTES:
            raise SystemExit(f"trace_fixtures: {name} is {len(text.encode())} bytes, over {MAX_BYTES}")
        with open(os.path.join(target, f"{name}.xml"), "w") as f:
            f.write(text)
    with open(os.path.join(target, "fixture.json"), "w") as f:
        json.dump({"xcode": xcode, "xctrace": version, "macos": macos, "emitter": {
            "subsystem": "com.cmuxterm.app.next", "category": "action", "signpost": "action.perform",
            "message": "id=fixture.spin origin=user input_age_ms=1.00", "rounds": 20, "spin_ms": 20,
            "spin_function": "fixtureSpin", "usleep_ms": 5}}, f, indent=1)
    shutil.rmtree(work, ignore_errors=True)
    print(f"trace_fixtures: wrote {target} ({version}, macOS {macos}): " +
          ", ".join(f"{n} {os.path.getsize(os.path.join(target, n + '.xml')) // 1000} kB" for n in exported))
    return 0


if __name__ == "__main__":
    sys.exit(main())
