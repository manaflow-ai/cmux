#!/usr/bin/env python3
"""Pin web/public/tui/install-static.sh by its sha256 everywhere cmux shows an install command.

cmuxterm-hq docs/design/linux-signed-packages.md, section 4 ("The installer, step by step") and the
detector in section 8. Leo, 2026-11-09: "Signed packages for anything we ship to Linux hosts (the
daemon on Cloud and SSH machines) instead of curl | sh."

A command cmux shows never pipes a moving URL into sh. It saves the script in a fresh `mktemp -d`
directory, checks it against a sha256 the command carries, and runs only the file it checked:

  app and CLI  https://cmux.com/tui/install-static/<sha256>.sh: an immutable copy of
               install-static.sh, named by its sha256 and never changed or removed (an app built
               with an older pin keeps working). The sha256 is the `install...static...sha256`
               constant in each SITES file.
  README.md    https://raw.githubusercontent.com/manaflow-ai/cmux/<commit>/web/public/tui/install-static.sh
               with its sha256: a pin that does not come from cmux.com. It may name an older commit
               than this tree's script; it must name the script that commit holds.

  install-static-pin.py           check (exit 1, with a next: line, on any difference)
  install-static-pin.py --write   write ARCHIVE/<sha256>.sh for this tree's script and set every SITES
                                  constant to its sha256 (README.md is moved by hand: it names a
                                  pushed commit)

The check also fails on any doc or app string that offers the bare `curl ... install-static.sh | sh`
(or `install.sh | sh`) for cmux. The bare URL itself keeps working; it is only no longer offered.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCRIPT = "web/public/tui/install-static.sh"
ARCHIVE = "web/public/tui/install-static"
README = "README.md"
# Each file holds one `install...static...sha256 = "<64 hex>"` constant: the pin its commands carry.
SITES = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextServer/AddDevice/AddDevicePlatform.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileModel/MachineInvite.swift",
    "cmux-tui/crates/acpmux/src/cli/pairing.rs",
    "web/app/lib/install-static-pin.ts",
)
# The value may sit on the next line (rustfmt wraps a long `const X: &str =`).
PIN = re.compile(r'install_?static_?sha256\b[^"\n]*(?:\n[ \t]*)?"([0-9a-f]*)"', re.IGNORECASE)
README_URL = re.compile(
    r"https://raw\.githubusercontent\.com/manaflow-ai/cmux/([0-9a-f]+)/web/public/tui/install-static\.sh"
    r' -o "\$d/install\.sh" && echo "([0-9a-f]+)  \$d/install\.sh"'
)
# A cmux installer URL (cmux.com or this repository), then a pipe into a shell on the same line,
# optionally behind env assignments: `| sh`, `| CMUX_HOST=1 sh`, `| bash -s -- --server`.
BARE = re.compile(
    r"(?:cmux\.com/tui/|manaflow-ai/cmux/[^\s/]+/web/public/tui/)install(?:-static)?\.sh\b"
    r"[^|\n]*\|\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:ba|z|da)?sh\b"
)
# Where a bare line is a doc or an app string. CI workflows run the live URL on purpose
# (cloud-vm-dogfood.yml's smoke) and are not docs.
SCANNED = re.compile(r"\.(md|swift|rs|ts|tsx|js|mjs|json|sh|py|txt|toml)$")
NOT_SCANNED = (".github/workflows/", "node_modules/")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read()


def git(*args, check=True):
    return subprocess.run(["git", "-C", ROOT, *args], check=check, capture_output=True)


def tracked_files():
    out = git("ls-files", "-z").stdout.decode()
    return [p for p in out.split("\0") if p]


def bare_lines(text):
    """(line number, line) of every bare `curl ... | sh` of a cmux installer in `text`."""
    return [(n, line.strip()) for n, line in enumerate(text.splitlines(), 1) if BARE.search(line)]


def readme_pin(text):
    """(commit, sha256) of README.md's pinned command, or None."""
    found = README_URL.findall(text)
    return found[0] if len(found) == 1 else None


def script_at(commit):
    """install-static.sh's bytes at `commit`, fetching the commit when this clone lacks it (CI clones
    are shallow). None when it cannot be read."""
    if git("cat-file", "-e", f"{commit}^{{commit}}", check=False).returncode != 0:
        git("fetch", "--no-tags", "--depth=1", "origin", commit, check=False)
    shown = git("show", f"{commit}:{SCRIPT}", check=False)
    return shown.stdout if shown.returncode == 0 else None


def check():
    errors = []
    want = sha256(read(SCRIPT))
    copy = f"{ARCHIVE}/{want}.sh"
    if not os.path.isfile(os.path.join(ROOT, copy)) or read(copy) != read(SCRIPT):
        errors.append(f"{copy} is missing or differs from {SCRIPT}")
    for name in sorted(os.listdir(os.path.join(ROOT, ARCHIVE))):
        got = sha256(read(f"{ARCHIVE}/{name}"))
        if name != f"{got}.sh":
            errors.append(f"{ARCHIVE}/{name}: its sha256 is {got}; a copy is named by its sha256 and never edited")
    for site in SITES:
        pins = PIN.findall(read(site).decode())
        if pins != [want]:
            errors.append(f"{site}: pins {pins or 'nothing'}, not {want} ({SCRIPT})")
    pin = readme_pin(read(README).decode())
    if pin is None:
        errors.append(f"{README}: no single pinned install command naming a commit's {SCRIPT}")
    else:
        commit, digest = pin
        at = script_at(commit) if re.fullmatch(r"[0-9a-f]{40}", commit) else None
        if at is None:
            errors.append(f"{README}: commit {commit} is not a full commit sha with {SCRIPT}")
        elif sha256(at) != digest:
            errors.append(f"{README}: pins {digest} for {commit}, but {SCRIPT} there is {sha256(at)}")
    for rel in tracked_files():
        if not SCANNED.search(rel) or rel.startswith(NOT_SCANNED) or not os.path.isfile(os.path.join(ROOT, rel)):
            continue
        try:
            text = read(rel).decode()
        except UnicodeDecodeError:
            continue
        for n, line in bare_lines(text):
            errors.append(f"{rel}:{n}: offers a bare curl | sh of the cmux installer: {line[:160]}")
    for e in errors:
        print(f"install-static-pin: {e}", file=sys.stderr)
    if errors:
        print("next: run python3 cmux-tui/scripts/install-static-pin.py --write, offer the pinned command "
              "(README.md's form) instead of a bare curl | sh, and commit the result", file=sys.stderr)
        return 1
    print(f"install-static-pin: {SCRIPT} pinned at {want} in {len(SITES)} sites; README.md pin {pin[0][:12]} ok")
    return 0


def write():
    data = read(SCRIPT)
    want = sha256(data)
    os.makedirs(os.path.join(ROOT, ARCHIVE), exist_ok=True)
    copy = os.path.join(ROOT, ARCHIVE, f"{want}.sh")
    if not os.path.exists(copy):
        with open(copy, "wb") as f:
            f.write(data)
    for site in SITES:
        text = read(site).decode()
        new, n = PIN.subn(lambda m: m.group(0).replace(f'"{m.group(1)}"', f'"{want}"'), text)
        if n != 1:
            print(f"install-static-pin: {site}: expected one pin constant, found {n}", file=sys.stderr)
            return 1
        if new != text:
            with open(os.path.join(ROOT, site), "w") as f:
                f.write(new)
    print(f"install-static-pin: wrote {ARCHIVE}/{want}.sh and pinned it in {len(SITES)} sites")
    return check()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true")
    return write() if parser.parse_args().write else check()


if __name__ == "__main__":
    sys.exit(main())
