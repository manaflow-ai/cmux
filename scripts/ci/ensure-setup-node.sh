#!/usr/bin/env bash
# Puts node VERSION on the job's PATH when actions/setup-node did not.
# Needs bash, curl, tar and sha256sum or shasum.
#
# setup-node can end "succeeded" with node never added: it logs "Attempting to download
# VERSION...", awaits the node-versions manifest, and when that request is dropped without an
# error the action's process runs out of work and exits 0 with nothing cached and nothing on PATH
# (nightly-next run 40551719327, build-nightly-app on an owned Mac with a cold tool cache; the
# web bundle build then failed "needs node 22.18 or newer on PATH (found: none)").
#
# This runs right after setup-node. Node VERSION on PATH: nothing to do. Otherwise it uses
# RUNNER_TOOL_CACHE/node/VERSION/ARCH when complete, else downloads nodejs.org's tarball (bounded
# curl with retries and a low-speed abort, checked against SHASUMS256.txt) into that same
# tool-cache layout, so later setup-node steps on this runner find it, and adds its bin to
# GITHUB_PATH.
#
#   ensure-setup-node.sh 24.22.1
set -euo pipefail

want="${1:?usage: ensure-setup-node.sh VERSION}"
# "vVERSION" when NODE runs, exits 0 and reports that version; empty when it fails.
runs_as() { local out; out="$("$1" --version 2>/dev/null)" || return 0; printf '%s' "$out"; }
if command -v node >/dev/null 2>&1 && [ "$(runs_as node)" = "v$want" ]; then
  echo "node v$want is on PATH ($(command -v node))"
  exit 0
fi
case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) echo "::error::ensure-setup-node: unsupported OS $(uname -s)"; exit 1 ;; esac
case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; x86_64) arch=x64 ;; *) echo "::error::ensure-setup-node: unsupported arch $(uname -m)"; exit 1 ;; esac
tool="${RUNNER_TOOL_CACHE:?RUNNER_TOOL_CACHE is not set}/node/$want/$arch"

version_of() { runs_as "$1/bin/node"; }

if [ ! -f "$tool.complete" ] || [ "$(version_of "$tool")" != "v$want" ]; then
  echo "::warning title=setup-node::node v$want is not on PATH after setup-node; installing it from nodejs.org"
  name="node-v$want-$os-$arch"
  base="${ENSURE_NODE_DIST:-https://nodejs.org/dist}/v$want"
  # Installed before anything is made so nothing leaks; signals trapped explicitly so every bash (3.2 too) cleans up.
  tmp="" stage="" lock="$tool.lock" locked=""
  trap 'rm -rf "$tmp" "$stage"; if [ -n "$locked" ]; then rmdir "$lock" 2>/dev/null || true; fi' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tmp="$(mktemp -d)"
  # Unpacked beside the tool cache entry so the install is one rename: jobs on one host share the cache.
  mkdir -p "$(dirname "$tool")"
  # A SIGKILLed job leaves its stage (an unpacked node) behind: drop this script's own, an hour old.
  find "$(dirname "$tool")" -maxdepth 1 -type d -name "$arch.??????" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  stage="$(mktemp -d "$tool.XXXXXX")"
  get() {
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 600 \
      --speed-limit 1024 --speed-time 60 -o "$2" "$1"
  }
  get "$base/$name.tar.gz" "$tmp/$name.tar.gz"
  get "$base/SHASUMS256.txt" "$tmp/SHASUMS256.txt"
  expected="$(awk -v f="$name.tar.gz" '$2 == f { print $1 }' "$tmp/SHASUMS256.txt")"
  if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "$tmp/$name.tar.gz" | awk '{ print $1 }')"
  else actual="$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{ print $1 }')"; fi
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "::error::ensure-setup-node: $name.tar.gz does not match SHASUMS256.txt (${expected:-no entry} vs $actual)"
    exit 1
  fi
  tar -xzf "$tmp/$name.tar.gz" -C "$stage"
  got="$(version_of "$stage/$name")"
  if [ "$got" != "v$want" ]; then
    echo "::error::ensure-setup-node: the downloaded node reports '${got:-nothing}', not v$want"
    exit 1
  fi
  # Check-and-replace runs under a lock: unlocked, a job could move aside an entry another job had just
  # renamed in and was about to run. A holder takes milliseconds; a killed one's lock is taken after a minute.
  tries=0
  until mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null || true)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    tries=$((tries + 1))
    if [ "$tries" -gt 300 ]; then echo "::error::ensure-setup-node: $lock held for 5 minutes"; exit 1; fi
    sleep 1
  done
  locked=1
  if [ "$(version_of "$tool")" = "v$want" ]; then
    # A working entry at this version is never moved: a finished job may be running it.
    echo "another job installed node v$want into $tool meanwhile; using it"
  else
    rm -f "$tool.complete"
    # A stale entry goes aside (one rename) so the new one can take its name; the trap deletes it.
    if [ -e "$tool" ]; then mv "$tool" "$stage/stale"; fi
    mv "$stage/$name" "$tool"
  fi
  touch "$tool.complete"
  rmdir "$lock" && locked=""
fi

if [ "$(version_of "$tool")" != "v$want" ]; then
  echo "::error::ensure-setup-node: $tool/bin/node does not run as v$want"
  exit 1
fi
echo "node v$want from $tool"
echo "$tool/bin" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
