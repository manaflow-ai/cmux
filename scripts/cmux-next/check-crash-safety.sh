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
#   tuple do/catch:    every tracked Swift file in the repo: no `do` with an
#                      `await` that returns a tuple while one of its `catch`
#                      clauses returns a tuple too. Swift 6.3 and 6.4 at -O never
#                      write the first element on the success path
#                      (swiftlang/swift#92698, #93118); a String there is garbage
#                      and copying it crashed the nightly (cx-21wc5). A catch
#                      that returns nil (optional tuple) counts too. Assign a
#                      local in the do/catch and return once, or return a struct.
#                      Heuristic: a catch that returns the tuple through a call
#                      (`return try await retry()`) is not seen.
#   ratchet:           crash_ratchet.py (plans/cmux-next/crash-elimination.md):
#                      no module or crate gains a force unwrap, as!, fatalError,
#                      precondition, assumeIsolated, unowned, implicitly
#                      unwrapped declaration or unchecked concurrency hit
#                      (Swift), or an unwrap/expect/panic!/exit (cmux-tui
#                      Rust), beyond crash-safety-baseline.json.
#
# Usage: scripts/cmux-next/check-crash-safety.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$root" <<'PY'
import os, re, subprocess, sys

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

def swift_sources():
    # Only tracked files count: ignored build or sync output in a per-job tree
    # must never fail the check (2026-10-07). Outside git it refuses (exit 2).
    try:
        # Paths relative to `sources` (git -C prints them relative to that directory).
        out = subprocess.run(["git", "-C", sources, "ls-files", "-z", "--", "."],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(sources, p) for p in out.split("\0") if p)
    except (OSError, subprocess.CalledProcessError) as error:
        # Walking every file counts build output: refuse, as crash_ratchet.py does (2026-10-09).
        print(f"check-crash-safety: refused: {sources} is not in a git checkout ({error})", file=sys.stderr)
        sys.exit(2)

failures = []
for path in swift_sources():
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

# swiftlang/swift#92698 (cx-21wc5): a tuple returned from an awaiting `do` and
# from its `catch` loses its first element at -O. Brace matching, not a regex:
# only the do body's own text and each catch body count.
DO_OPEN = re.compile(r"\bdo(?:\s+throws\s*(?:\([^)]*\))?)?\s*\{")
CATCH_OPEN = re.compile(r"(?:\s|//[^\n]*\n)*catch\b[^{]*\{")
TUPLE_RETURN = re.compile(r"\breturn\s*\(")
# The catch side also counts when it returns nil: the optional-tuple shape
# (`(A, B)?` from the do, nil from the catch) is untested upstream; keep the
# tuple out of the do/catch there too.
CATCH_RETURN = re.compile(r"\breturn\s*(?:\(|nil\b)")

def block_end(text, open_brace):
    depth = 0
    for i in range(open_brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1

def tuple_do_catch_hits(text):
    for match in DO_OPEN.finditer(text):
        end = block_end(text, match.end() - 1)
        if end < 0:
            continue
        body = text[match.end():end]
        if "await" not in body or not TUPLE_RETURN.search(body):
            continue
        cursor = end + 1
        while (clause := CATCH_OPEN.match(text, cursor)):
            clause_end = block_end(text, clause.end() - 1)
            if clause_end < 0:
                break
            if CATCH_RETURN.search(text[clause.end():clause_end]):
                yield text.count("\n", 0, match.start())
                break
            cursor = clause_end + 1

repo = os.path.abspath(os.path.join(root, "..", "..", ".."))
try:
    tracked = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", "*.swift"],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
except (OSError, subprocess.CalledProcessError) as error:
    print(f"check-crash-safety: refused: {repo} is not in a git checkout ({error})", file=sys.stderr)
    sys.exit(2)
for rel in sorted(p for p in tracked.split("\0") if p.endswith(".swift")):
    path = os.path.join(repo, rel)
    if not os.path.isfile(path):
        continue
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    for index in tuple_do_catch_hits("\n".join(lines)):
        if not allowed(lines, index):
            failures.append(f"{rel}:{index + 1}: tuple returned from an awaiting do and its catch "
                            "(swiftlang/swift#92698 drops its first element at -O): assign a local, return once")

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
python3 "$here/crash_ratchet.py" --repo "$(cd "$root/../../.." && pwd)"
