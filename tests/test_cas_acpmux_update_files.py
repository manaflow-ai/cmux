#!/usr/bin/env python3
"""scripts/cas/acpmux_update_files.py against a local channel folder (--channel-dir): every acpmux binary
gets its .zst and a patch from the channel's build, each of which decodes back to the binary; a channel
already on this tree, a target the channel lacks, and an old binary of another sha256 get no patch, and a
tree key whose published binary is other bytes gets nothing."""
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts/cas/acpmux_update_files.py")
A = "cmux-tui-acpmux-x86_64-unknown-linux-musl"
B = "cmux-tui-acpmux-aarch64-apple-darwin"


def sha(b):
    return hashlib.sha256(b).hexdigest()


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def run(t, channels, keys=("new",)):
    out = os.path.join(t, "out")
    shutil.rmtree(out, ignore_errors=True)
    args = [sys.executable, SCRIPT, "--assets-dir", os.path.join(t, "assets"), "--channel-dir", os.path.join(t, "cdn"),
            "--out-dir", out]
    for k in keys:
        args += ["--key", k]
    for c in channels:
        args += ["--channel", c]
    p = subprocess.run(args, check=True, capture_output=True, text=True)
    return sorted(os.listdir(out)), p.stdout


def decode(t, packed, old=None):
    extra = [f"--patch-from={old}"] if old else []
    return subprocess.run(["zstd", "-q", "-d", "--long=31", *extra, "-c", packed], check=True,
                          capture_output=True).stdout


def main():
    if shutil.which("zstd") is None:
        print("skip: no zstd")
        return
    with tempfile.TemporaryDirectory() as t:
        rng = random.Random(7)
        old = bytes(rng.getrandbits(8) for _ in range(300_000))
        new = old[:1000] + b"changed" + old[1000:]
        write(os.path.join(t, "assets", A), new)
        write(os.path.join(t, "assets", B), new + b"darwin")
        write(os.path.join(t, "assets", A + ".sha256"), b"x")
        write(os.path.join(t, "cdn/tree/old", A), old)
        write(os.path.join(t, "cdn/tree/new", A + ".sha256"), f"{sha(new)}  {A}\n".encode())
        write(os.path.join(t, "cdn/tree/new", B + ".sha256"), f"{sha(new + b'darwin')}  {B}\n".encode())
        # Another key's tree holds other bytes: nothing is made for it.
        write(os.path.join(t, "cdn/tree/other", A + ".sha256"), f"{'1' * 64}  {A}\n".encode())
        write(os.path.join(t, "cdn/channels/feat-cmux-next.json"),
              json.dumps({"key": "old", "commit": "c", "binaries": {A: sha(old)}}).encode())
        write(os.path.join(t, "cdn/channels/same.json"),
              json.dumps({"key": "new", "commit": "c", "binaries": {A: sha(new)}}).encode())
        write(os.path.join(t, "cdn/channels/liar.json"),
              json.dumps({"key": "old", "commit": "c", "binaries": {A: "0" * 64}}).encode())

        files, stdout = run(t, ["feat-cmux-next", "same", "liar", "missing"], keys=("new", "other"))
        assert "tree/other/" in stdout and "no update files" in stdout, stdout
        patch = f"{A}.from-{sha(old)}.zst"
        assert files == sorted([f"{A}.zst", f"{B}.zst", patch]), files
        out = os.path.join(t, "out")
        assert decode(t, os.path.join(out, f"{A}.zst")) == new
        assert decode(t, os.path.join(out, f"{B}.zst")) == new + b"darwin"
        assert decode(t, os.path.join(out, patch), os.path.join(t, "cdn/tree/old", A)) == new
        # Random bytes do not compress, but a patch against a near-identical build is tiny.
        assert os.path.getsize(os.path.join(out, patch)) < len(new) // 20
        assert "liar" not in stdout and "files" in json.loads(stdout[stdout.index("{"):])
    print("ok")


if __name__ == "__main__":
    main()
