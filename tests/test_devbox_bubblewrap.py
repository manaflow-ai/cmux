#!/usr/bin/env python3
"""Build and exercise the devbox bubblewrap layer on an Ubuntu Docker host."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
dockerfile = (root / "web/services/vms/images/devbox/Dockerfile").read_text()
instructions = re.sub(r"\\\n", " ", dockerfile).splitlines()
# Execute the image's real devtools and bubblewrap recipes, without baking
# unrelated agents or the desktop. The old recipe installs Ubuntu's 0.9.0.
devtools = next(line for line in instructions if line.startswith("RUN apt-get update && apt-get install"))
pins = [line for line in instructions if line.startswith("ARG CMUX_IMAGE_BUBBLEWRAP_")]
install = [line for line in instructions if line.startswith("RUN ") and "/tmp/bubblewrap.tar.xz" in line]
recipe = "\n".join(["FROM ubuntu:24.04", "ENV DEBIAN_FRONTEND=noninteractive", devtools, *pins, *install]) + "\n"
tag = f"cmux-bubblewrap-test-{os.getpid()}"
probe = r'''set -eux
version=$(bwrap --version)
test "$(command -v bwrap)" = /usr/bin/bwrap
# Muse rejects the old distro bubblewrap. Keep a minimum independent of the
# recipe's version assertion so a downgrade fails this regression.
test "$(printf '%s\n' 0.13.1 "${version#bubblewrap }" | sort -V | head -1)" = 0.13.1
test ! -u /usr/bin/bwrap
before=$(sha256sum /usr/bin/bwrap)
apt-get update
apt-get install -y --no-install-recommends --reinstall bubblewrap
test "$(sha256sum /usr/bin/bwrap)" = "$before"
test "$(bwrap --version)" = "$version"
# Muse's --ro-bind-symlink belongs to its patched helper, not upstream bwrap.
runuser -u nobody -- bwrap --ro-bind / / --unshare-user --unshare-pid --proc /proc --dev /dev -- /bin/true
echo bubblewrap-install-and-sandbox-ok
'''
try:
    with tempfile.TemporaryDirectory(prefix="cmux-bubblewrap-") as context:
        subprocess.run(["docker", "build", "--tag", tag, "--file", "-", context], input=recipe, text=True, check=True)
    subprocess.run(["docker", "run", "--rm", "--security-opt", "seccomp=unconfined", "--security-opt", "apparmor=unconfined", "--security-opt", "systempaths=unconfined", tag, "sh", "-c", probe], check=True)
finally:
    subprocess.run(["docker", "image", "rm", tag], check=False)
