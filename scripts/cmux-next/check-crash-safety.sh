#!/usr/bin/env bash
# Static crash-safety rules for cmux-next (plans/cmux-next/browser-isolation.md,
# "Crash safety rules"). A hit is allowed only with a reviewed
# `// crash-allow: <reason>` on the same line or the comment line above.
#
#   everywhere:        no `try!`.
#   external data:     CmuxNextDaemon, CmuxNextControl and CmuxNextMobile decode
#                      daemon, socket and phone input: no force unwrap (`x!`)
#                      and no `as!`.
#   SIGPIPE:           a file that makes or accepts a socket must say how its
#                      writes avoid SIGPIPE (SO_NOSIGPIPE or MSG_NOSIGNAL), and
#                      the app entry point must install the SIGPIPE policy
#                      (ChildSignalDefaults: caught by a no-op handler, so a
#                      write fails with EPIPE and children still get the
#                      default; ChildSignalDefaultsTests proves both).
#
# Usage: scripts/cmux-next/check-crash-safety.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
exec python3 - "$root" <<'PY'
import os, re, sys

root = sys.argv[1]
sources = os.path.join(root, "Sources")
EXTERNAL = {"CmuxNextDaemon", "CmuxNextControl", "CmuxNextMobile"}
ALLOW = re.compile(r"//\s*crash-allow:\s*\S")
TRY_BANG = re.compile(r"\btry!")
FORCE = re.compile(r"(?<![!=<>])[\w\)\]]!(?!=)(?=[\s\.\),\]\[;:]|$)|\bas!\s")
SOCKET = re.compile(r"\bsocket\(AF_|(?<![.\w])accept\(\w+, *(nil|&)|\bsocketpair\(")
NOSIGPIPE = re.compile(r"SO_NOSIGPIPE|MSG_NOSIGNAL")

def code_of(line):
    # Strip a trailing comment when no string literal could contain "//".
    return line.split("//", 1)[0] if '"' not in line else line

def allowed(lines, index):
    return bool(ALLOW.search(lines[index]) or (index > 0 and ALLOW.search(lines[index - 1])))

failures = []
for dirpath, _, files in os.walk(sources):
    for name in sorted(files):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        module = os.path.relpath(path, sources).split(os.sep)[0]
        lines = open(path, encoding="utf-8").read().split("\n")
        text = "\n".join(lines)
        for index, line in enumerate(lines):
            if line.lstrip().startswith("//"):
                continue
            code = code_of(line)
            if TRY_BANG.search(code) and not allowed(lines, index):
                failures.append(f"{rel}:{index + 1}: try! (throw a typed error instead)")
            if module in EXTERNAL and FORCE.search(code) and not allowed(lines, index):
                failures.append(f"{rel}:{index + 1}: force unwrap or as! in a module that decodes external data")
        if SOCKET.search(text) and not NOSIGPIPE.search(text):
            failures.append(f"{rel}: makes or accepts a socket without SO_NOSIGPIPE or MSG_NOSIGNAL")

entry = os.path.join(sources, "CmuxNextApp", "CmuxNextApp.swift")
if "ChildSignalDefaults.installAppSignalPolicy()" not in open(entry, encoding="utf-8").read():
    failures.append("Sources/CmuxNextApp/CmuxNextApp.swift: the entry point must call ChildSignalDefaults.installAppSignalPolicy()")

for failure in failures:
    print("crash-safety: " + failure)
if failures:
    print(f"check-crash-safety: {len(failures)} violation(s). Fix it, or add a reviewed `// crash-allow: <reason>`.")
    sys.exit(1)
print("check-crash-safety: ok")
PY
