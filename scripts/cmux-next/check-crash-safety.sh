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
#   ratchet:           crash_ratchet.py (plans/cmux-next/crash-elimination.md):
#                      no module or crate gains a force unwrap, as!, fatalError,
#                      precondition, assumeIsolated, unowned, implicitly
#                      unwrapped declaration or unchecked concurrency hit
#                      (Swift), or an unwrap/expect/panic!/exit (cmux-tui
#                      Rust), beyond crash-safety-baseline.json.
#
#   --mobile:          the cmux-next iOS tree (every root in
#                      mobile-scan-roots.txt; the argument is the repo root):
#                      no `try!` and the SIGPIPE rule. Force unwraps and the
#                      other crash classes are held by the ratchet, which
#                      counts these roots too.
#
# Usage: scripts/cmux-next/check-crash-safety.sh [package-root]
#        scripts/cmux-next/check-crash-safety.sh --mobile [repo-root]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode=macos
if [[ "${1:-}" == --mobile ]]; then
  mode=mobile
  shift
  repo="${1:-$(git rev-parse --show-toplevel)}"
  root="$repo"
else
  root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
  repo="$(cd "$root/../../.." && pwd)"
fi
python3 - "$root" "$mode" "$repo" <<'PY'
import os, re, subprocess, sys

root = sys.argv[1]
MOBILE = sys.argv[2] == "mobile"
repo = sys.argv[3]
if MOBILE:
    with open(os.path.join(root, "scripts/cmux-next/mobile-scan-roots.txt"), encoding="utf-8") as handle:
        entries = [line.strip() for line in handle]
    source_roots = [os.path.join(root, e, "Sources") for e in entries if e and not e.startswith("#")]
else:
    source_roots = [os.path.join(root, "Sources")]
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

def tracked_swift_files(sources):
    """Return tracked Swift files, ignoring per-job build/sync output."""
    try:
        rel = os.path.relpath(sources, repo)
        out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", rel],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(repo, path) for path in out.split("\0") if path)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"check-crash-safety: WARNING: {sources} is not in a git checkout ({error}); scanning every file", file=sys.stderr)
        return sorted(os.path.join(directory, name)
                      for directory, _, names in os.walk(sources) for name in names)

failures = []
for sources in source_roots:
  for path in tracked_swift_files(sources):
        name = os.path.basename(path)
        if not name.endswith(".swift") or not os.path.isfile(path):
            continue
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

entry = os.path.join(root if not MOBILE else repo, "Sources", "CmuxNextApp", "CmuxNextApp.swift")
if not MOBILE and "ChildSignalDefaults.installAppSignalPolicy()" not in open(entry, encoding="utf-8").read():
    failures.append("Sources/CmuxNextApp/CmuxNextApp.swift: the entry point must call ChildSignalDefaults.installAppSignalPolicy()")

for failure in failures:
    print("crash-safety: " + failure)
if failures:
    print(f"check-crash-safety: {len(failures)} violation(s). Fix it, or add a reviewed `// crash-allow: <reason>`.")
    sys.exit(1)
print("check-crash-safety: ok")
PY
python3 "$here/crash_ratchet.py" --repo "$repo"
