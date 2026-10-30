#!/usr/bin/env python3
"""The shared repo of the Austin's-day scenario: a partial clone whose .git holds thousands of packs.

  packs.py build ROOT [--packs 19110] [--worktrees 8] [--files 400] [--commits 60]
  packs.py check ROOT

Austin's shared repo had 19,110 packs in one .git (a `--filter=blob:none` clone whose maintenance
never ran, fetched many times). Each git command there opens the pack list and searches pack
indexes one by one, so every `git status` an agent runs costs a walk over thousands of indexes.

build makes the same shape cheaply, once per host (it is kept under ROOT and reused):
- ROOT/upstream.git: a bare repo with --files text files and --commits commits (git fast-import,
  one process), uploadpack.allowFilter on;
- ROOT/clone: `git clone --filter=blob:none file://.../upstream.git` (a promisor remote), with
  gc.auto=0 and maintenance off, so nothing repacks it;
- --worktrees worktrees ROOT/wt-N of the clone (their checkouts fetch blobs on demand, as a
  partial clone does), all sharing the clone's one .git;
- a few real fetches of new upstream commits (each one keeps its pack: fetch.unpackLimit=1);
- then the rest of the --packs packs written directly: each is a valid version 2 pack of one
  blob object with its version 2 index and a `.promisor` file, as a promisor fetch leaves them.
  Writing them in this process takes seconds; 19,110 `git pack-objects` runs would take minutes.
check counts the packs and runs `git count-objects -v` and `git fsck --connectivity-only` on a
sample. A finished build writes ROOT/READY with its parameters; build with the same ones skips.
"""
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import zlib


def git(*args, cwd=None, input=None, env=None):
    done = subprocess.run(["git", *args], cwd=cwd, input=input, capture_output=True, env=env)
    if done.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {done.stderr.decode(errors='replace')[:400]}")
    return done.stdout.decode(errors="replace")


def fast_import_stream(files, commits):
    """A fast-import stream: `commits` commits, each changing files of the tree of `files` files."""
    out = []
    mark = 0
    when = 1767225600
    for c in range(commits):
        mark += 1
        message = f"austins day commit {c}\n".encode()
        out.append(b"commit refs/heads/main\n")
        out.append(f"mark :{mark}\n".encode())
        out.append(f"committer Austin Day <ad@example.invalid> {when + c * 60} +0000\n".encode())
        out.append(f"data {len(message)}\n".encode() + message)
        if c:
            out.append(f"from :{mark - 1}\n".encode())
        changed = range(files) if c == 0 else [(c * 7 + k) % files for k in range(max(1, files // 20))]
        for index in changed:
            body = (f"file {index} revision {c}\n" + "lorem ipsum dolor sit amet needle\n" * (20 + index % 40)).encode()
            path = f"dir{index % 20}/file{index}.txt"
            out.append(f"M 644 inline {path}\n".encode())
            out.append(f"data {len(body)}\n".encode() + body)
        out.append(b"\n")
    return b"".join(out)


def pack_one_blob(pack_dir, content):
    """Writes pack-<sha>.pack/.idx/.promisor holding one blob; returns the pack name."""
    header = f"blob {len(content)}\0".encode()
    oid = hashlib.sha1(header + content).digest()
    # Object header: type 3 (blob), size in the variable-length encoding.
    size = len(content)
    first = (3 << 4) | (size & 0x0F)
    size >>= 4
    encoded = bytearray()
    while True:
        if size:
            encoded.append(first | 0x80)
            first = size & 0x7F
            size >>= 7
        else:
            encoded.append(first)
            break
    body = bytes(encoded) + zlib.compress(content)
    data = b"PACK" + struct.pack(">II", 2, 1) + body
    trailer = hashlib.sha1(data).digest()
    pack = data + trailer
    offset = 12
    crc = zlib.crc32(body) & 0xFFFFFFFF
    # Index version 2: magic, version, 256-entry fanout, names, CRCs, offsets, pack and index checksums.
    fanout = [0] * 256
    for b in range(oid[0], 256):
        fanout[b] = 1
    idx = b"\377tOc" + struct.pack(">I", 2) + b"".join(struct.pack(">I", n) for n in fanout)
    idx += oid + struct.pack(">I", crc) + struct.pack(">I", offset) + trailer
    idx += hashlib.sha1(idx).digest()
    name = f"pack-{trailer.hex()}"
    for suffix, payload in ((".pack", pack), (".idx", idx), (".promisor", b"")):
        path = os.path.join(pack_dir, name + suffix)
        with open(path + ".tmp", "wb") as f:
            f.write(payload)
        os.replace(path + ".tmp", path)
    return name


def pack_dir_of(root):
    return os.path.join(root, "clone", ".git", "objects", "pack")


def count_packs(root):
    return sum(1 for name in os.listdir(pack_dir_of(root)) if name.endswith(".pack"))


def build(opts):
    root = os.path.abspath(opts.root)
    params = {"packs": opts.packs, "worktrees": opts.worktrees, "files": opts.files, "commits": opts.commits, "v": 1}
    ready = os.path.join(root, "READY")
    if os.path.exists(ready):
        try:
            with open(ready) as f:
                kept = json.load(f).get("params") or {}
            # `made` is what the build produced, not a parameter (review of aa7c09ebaed, finding 4: comparing
            # it made every run rebuild the 19,110 packs inside its lease).
            if {k: v for k, v in kept.items() if k != "made"} == params:
                print(f"packs: {root} is ready ({count_packs(root)} packs)")
                return
        except ValueError:
            pass
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}
    upstream = os.path.join(root, "upstream.git")
    git("init", "--bare", "-q", "-b", "main", upstream, env=env)
    git("config", "uploadpack.allowFilter", "true", cwd=upstream, env=env)
    git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=upstream, env=env)
    git("fast-import", "--quiet", cwd=upstream, input=fast_import_stream(opts.files, opts.commits), env=env)
    clone = os.path.join(root, "clone")
    git("clone", "-q", "--filter=blob:none", "--no-checkout", f"file://{upstream}", clone, env=env)
    for key, value in (("gc.auto", "0"), ("gc.autoPackLimit", "0"), ("maintenance.auto", "false"),
                       ("fetch.unpackLimit", "1"), ("transfer.unpackLimit", "1"), ("core.untrackedCache", "false"),
                       ("user.name", "Austin Day"), ("user.email", "ad@example.invalid")):
        git("config", key, value, cwd=clone, env=env)
    git("checkout", "-q", "main", cwd=clone, env=env)
    for n in range(opts.worktrees):
        git("worktree", "add", "-q", "-b", f"wt-{n}", os.path.join(root, f"wt-{n}"), "main", cwd=clone, env=env)
    # A few real fetches: new upstream commits each time; each fetch keeps its own promisor pack.
    scratch = os.path.join(root, "scratch")
    git("clone", "-q", f"file://{upstream}", scratch, env=env)
    for f in range(min(20, opts.packs)):
        with open(os.path.join(scratch, f"fetch-{f}.txt"), "w") as fh:
            fh.write(f"fetch {f}\n" * 50)
        git("add", ".", cwd=scratch, env=env)
        git("-c", "user.name=ad", "-c", "user.email=ad@example.invalid", "commit", "-q", "-m", f"fetch {f}", cwd=scratch, env=env)
        git("push", "-q", "origin", "HEAD:main", cwd=scratch, env=env)
        git("fetch", "-q", "origin", cwd=clone, env=env)
    shutil.rmtree(scratch)
    pack_dir = pack_dir_of(root)
    have = count_packs(root)
    for n in range(max(0, opts.packs - have)):
        pack_one_blob(pack_dir, f"austins day promisor blob {n}\n".encode())
    made = count_packs(root)
    with open(ready, "w") as f:
        json.dump({"params": {**params, "made": made}}, f)
    print(f"packs: built {root}: {made} packs, {opts.worktrees} worktrees")


def check(opts):
    root = os.path.abspath(opts.root)
    clone = os.path.join(root, "clone")
    print(json.dumps({"packs": count_packs(root), "count_objects": git("count-objects", "-v", cwd=clone).split("\n"),
                      "status_lines": len(git("status", "--porcelain", cwd=os.path.join(root, "wt-0")).splitlines())}))
    git("fsck", "--connectivity-only", "--no-dangling", cwd=clone)
    print("packs: fsck ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("root")
    b.add_argument("--packs", type=int, default=19110)
    b.add_argument("--worktrees", type=int, default=8)
    b.add_argument("--files", type=int, default=400)
    b.add_argument("--commits", type=int, default=60)
    c = sub.add_parser("check")
    c.add_argument("root")
    opts = parser.parse_args()
    (build if opts.cmd == "build" else check)(opts)


if __name__ == "__main__":
    sys.exit(main())
