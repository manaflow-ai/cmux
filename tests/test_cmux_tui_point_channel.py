#!/usr/bin/env python3
"""The feat-cmux-next channel pointer only moves forward, and fails closed.

Linux hosts follow cmux-tui/channels/feat-cmux-next.json by themselves
(`acpmux host self-update`), so a pointer that moves back downgrades every one
of them. The review of #24232 reproduced two ways it did: two feat-cmux-next
pushes ran scripts/ci/cmux-tui-point-channel.sh at once and the older one wrote
last, and a compare that failed (an API error) gave an empty status, which the
script took as "not behind". The pointer now moves only when the compare says
"ahead" (or there is no pointer yet), and its write is a compare-and-swap on
the bytes that were compared, read again when another run wrote first.

This runs the real script with a fake curl (files.cmux.com and the compare
API) and a fake upload-r2-object.py beside it that keeps the object in a file.
"""

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "cmux-tui-point-channel.sh")
FAILURES = []

KEY = "0123456789abcdef0123456789abcdef01234567"
# The branch's commits, oldest first: the fake compare answers from this order.
OLDER, OLD, SHA, NEWER = ("a" * 40, "b" * 40, "c" * 40, "d" * 40)
ORDER = [OLDER, OLD, SHA, NEWER]


def _check(ok, message):
    if not ok:
        FAILURES.append(message)


# files.cmux.com and GitHub's compare API. The channel object is $STATE/object
# (absent: 404); FAKE_READ_CODE overrides its status, FAKE_COMPARE=fail makes
# the compare fail and FAKE_COMPARE=junk answer something that is not JSON.
FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http")).split("?")[0]
state = os.environ["STATE"]
open(os.path.join(state, "curl.log"), "a").write(url + "\n")
out = args[args.index("-o") + 1] if "-o" in args else None
if "/compare/" in url:
    mode = os.environ.get("FAKE_COMPARE", "")
    if mode == "fail":
        sys.exit(22)
    if mode == "junk":
        print("<html>rate limited</html>")
        sys.exit(0)
    base, head = url.rsplit("/", 1)[1].split("...")
    order = os.environ["FAKE_ORDER"].split(",")
    if base not in order:
        status = "diverged"
    else:
        a, b = order.index(base), order.index(head)
        status = "ahead" if b > a else "behind" if b < a else "identical"
    print(json.dumps({"status": status}))
    sys.exit(0)
name = url.rsplit("/", 1)[1]
if name == "daemon-tests.json":
    sys.exit(0 if os.environ.get("FAKE_MARKER", "1") == "1" else 22)
if name == "completion.json":
    key = url.split("/tree/")[1].split("/")[0]
    body = json.dumps({"key": key, "binaries": {
        "cmux-tui-acpmux-x86_64-unknown-linux-musl": "1" * 64,
        "cmux-tui-acpmux-aarch64-unknown-linux-musl": "2" * 64,
        "cmux-tui-x86_64-unknown-linux-musl": "3" * 64,
    }})
    open(out, "w").write(body)
    sys.exit(0)
if url.endswith("/channels/feat-cmux-next.json"):
    path = os.path.join(state, "object")
    code = os.environ.get("FAKE_READ_CODE") or ("200" if os.path.exists(path) else "404")
    if code == "200":
        open(out, "wb").write(open(path, "rb").read())
    sys.stdout.write(code)
    sys.exit(0)
sys.exit(22)
"""

# upload-r2-object.py's compare-and-swap, on $STATE/object. $STATE/race, when
# there, is another run's write that lands right before this one's (once).
FAKE_UPLOAD = r"""#!/usr/bin/env python3
import argparse, hashlib, os, sys
p = argparse.ArgumentParser()
for flag in ("--file", "--endpoint-url", "--bucket", "--key", "--cache-control", "--content-type", "--replace-sha256"):
    p.add_argument(flag)
p.add_argument("--write-once", action="store_true")
p.add_argument("--conflict-exit-code", type=int, default=1)
a = p.parse_args()
state = os.environ["STATE"]
path, race = os.path.join(state, "object"), os.path.join(state, "race")
mode = "write-once" if a.write_once else "replace" if a.replace_sha256 else "plain"
open(os.path.join(state, "upload.log"), "a").write(f"{mode} {a.key}\n")
if os.path.exists(race):
    os.replace(race, path)
body = open(a.file, "rb").read()
current = open(path, "rb").read() if os.path.exists(path) else None
if a.write_once and current is not None and current != body:
    sys.exit(a.conflict_exit_code)
if a.replace_sha256 and (current is None or hashlib.sha256(current).hexdigest() != a.replace_sha256):
    sys.exit(a.conflict_exit_code)
if mode == "plain":
    sys.exit(9)
open(path, "wb").write(body)
"""


def pointer(commit, key=KEY):
    return json.dumps({"key": key, "commit": commit, "binaries": {}}, indent=2, sort_keys=True)


def run(current=None, race=None, **env):
    """The script for SHA with the channel at `current` (text, or None for no
    file); its exit, output, the channel afterwards and the uploads."""
    with tempfile.TemporaryDirectory() as tmp:
        ci, bin_dir, state = (os.path.join(tmp, d) for d in ("ci", "bin", "state"))
        for d in (ci, bin_dir, state):
            os.makedirs(d)
        script = os.path.join(ci, "cmux-tui-point-channel.sh")
        shutil.copy(SCRIPT, script)
        for path, text in ((os.path.join(bin_dir, "curl"), FAKE_CURL), (os.path.join(ci, "upload-r2-object.py"), FAKE_UPLOAD)):
            with open(path, "w") as handle:
                handle.write(text)
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        os.chmod(script, os.stat(script).st_mode | stat.S_IXUSR)
        if current is not None:
            open(os.path.join(state, "object"), "w").write(current)
        if race is not None:
            open(os.path.join(state, "race"), "w").write(race)
        full = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", STATE=state, GITHUB_SHA=SHA,
                    GITHUB_RUN_ID="5", GITHUB_API_URL="https://api.github.invalid",
                    GITHUB_REPOSITORY="manaflow-ai/cmux", GH_TOKEN="x", R2_ENDPOINT="https://r2.invalid",
                    FAKE_ORDER=",".join(ORDER), **env)
        result = subprocess.run(["bash", script, "feat-cmux-next", KEY], env=full, capture_output=True,
                                text=True, timeout=60)
        path = os.path.join(state, "object")
        after = open(path).read() if os.path.exists(path) else None
        log = os.path.join(state, "upload.log")
        uploads = open(log).read().splitlines() if os.path.exists(log) else []
        return result, after, uploads


def commit_of(text):
    try:
        return json.loads(text).get("commit")
    except (TypeError, ValueError):
        return None


def main():
    # No pointer yet: the first write, which must not replace one another run wrote.
    result, after, uploads = run()
    _check(result.returncode == 0 and commit_of(after) == SHA, f"a first pointer is written: {result.stdout}{result.stderr}")
    _check(uploads == ["write-once cmux-tui/channels/feat-cmux-next.json"], f"the first write is write-once: {uploads}")
    channel = json.loads(after or "{}")
    _check(channel.get("key") == KEY and sorted(channel.get("binaries", {})) == [
        "cmux-tui-acpmux-aarch64-unknown-linux-musl", "cmux-tui-acpmux-x86_64-unknown-linux-musl"],
        f"the pointer names the tree and only its acpmux binaries: {after}")

    # An older commit: moved, by a swap on the bytes that were compared.
    result, after, uploads = run(pointer(OLD))
    _check(result.returncode == 0 and commit_of(after) == SHA, f"an older pointer moves forward: {result.stdout}{result.stderr}")
    _check(uploads == ["replace cmux-tui/channels/feat-cmux-next.json"], f"the move is a compare-and-swap: {uploads}")

    # Everything but "ahead" leaves the pointer, exit 0.
    cases = [
        ("a newer pointer", pointer(NEWER), {}),
        ("a pointer on a commit the branch does not have (diverged)", pointer("e" * 40), {}),
        ("the same commit (identical)", pointer(SHA, key="f" * 40), {}),
        ("a compare that fails", pointer(OLD), {"FAKE_COMPARE": "fail"}),
        ("a compare that answers no status", pointer(OLD), {"FAKE_COMPARE": "junk"}),
        ("a channel read that fails", pointer(OLD), {"FAKE_READ_CODE": "503"}),
        ("a channel read with no answer", pointer(OLD), {"FAKE_READ_CODE": "000"}),
    ]
    for why, current, env in cases:
        result, after, uploads = run(current, **env)
        _check(result.returncode == 0 and after == current and not uploads,
               f"{why}: left as it is (exit {result.returncode}, uploads {uploads}): {result.stdout}{result.stderr}")

    # A file that names no commit proves nothing about ancestry: an older run
    # must not overwrite it, so it is left for a person to look at.
    for why, current in [
        ("a pointer that is not JSON", "not json"),
        ("a pointer without a commit", '{"key": "' + "a" * 40 + '"}'),
        ("a pointer with a malformed commit", pointer("not-a-commit")),
    ]:
        result, after, uploads = run(current)
        _check(result.returncode == 0 and after == current and not uploads,
               f"{why}: left as it is (exit {result.returncode}, uploads {uploads}): {result.stdout}{result.stderr}")

    # Two runs at once: a newer push writes between this run's compare and its
    # write. The swap fails, the pointer is read again, and this run, now
    # behind, leaves the newer pointer.
    result, after, uploads = run(pointer(OLDER), race=pointer(NEWER))
    _check(result.returncode == 0 and commit_of(after) == NEWER,
           f"an older run that loses the race never moves the pointer back: {after} {result.stdout}{result.stderr}")
    _check(len(uploads) == 1, f"one write attempt, then a read: {uploads}")
    # An older push writes first: this run reads it, is still ahead, and writes.
    result, after, uploads = run(pointer(OLDER), race=pointer(OLD))
    _check(result.returncode == 0 and commit_of(after) == SHA and len(uploads) == 2,
           f"a newer run that loses the race tries again: {uploads} {result.stdout}{result.stderr}")
    # Another run writes the first pointer first: this one compares with it.
    result, after, uploads = run(None, race=pointer(NEWER))
    _check(result.returncode == 0 and commit_of(after) == NEWER,
           f"a first write that loses the race compares again: {after} {result.stdout}{result.stderr}")

    # A tree that is not daemon-tested is not pointed at.
    result, after, uploads = run(pointer(OLD), FAKE_MARKER="0")
    _check(result.returncode == 0 and commit_of(after) == OLD and not uploads, "an untested tree is not pointed at")

    if FAILURES:
        for failure in FAILURES:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: the feat-cmux-next channel moves only forward and fails closed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
