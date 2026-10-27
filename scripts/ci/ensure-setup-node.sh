#!/usr/bin/env bash
# Puts node VERSION on the job's PATH when actions/setup-node did not.
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
if [ "$(node --version 2>/dev/null || true)" = "v$want" ]; then
  echo "node v$want is on PATH ($(command -v node))"
  exit 0
fi
case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) echo "::error::ensure-setup-node: unsupported OS $(uname -s)"; exit 1 ;; esac
case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; x86_64) arch=x64 ;; *) echo "::error::ensure-setup-node: unsupported arch $(uname -m)"; exit 1 ;; esac
tool="${RUNNER_TOOL_CACHE:?RUNNER_TOOL_CACHE is not set}/node/$want/$arch"

if [ ! -f "$tool.complete" ] || [ ! -x "$tool/bin/node" ]; then
  echo "::warning title=setup-node::node v$want is not on PATH after setup-node; installing it from nodejs.org"
  name="node-v$want-$os-$arch"
  base="${ENSURE_NODE_DIST:-https://nodejs.org/dist}/v$want"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  get() {
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 600 \
      --speed-limit 1024 --speed-time 60 -o "$2" "$1"
  }
  get "$base/$name.tar.gz" "$tmp/$name.tar.gz"
  get "$base/SHASUMS256.txt" "$tmp/SHASUMS256.txt"
  expected="$(awk -v f="$name.tar.gz" '$2 == f { print $1 }' "$tmp/SHASUMS256.txt")"
  actual="$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{ print $1 }')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "::error::ensure-setup-node: $name.tar.gz does not match SHASUMS256.txt (${expected:-no entry} vs $actual)"
    exit 1
  fi
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
  rm -rf "$tool" "$tool.complete"
  mkdir -p "$(dirname "$tool")"
  mv "$tmp/$name" "$tool"
  touch "$tool.complete"
fi

echo "node $("$tool/bin/node" --version) from $tool"
echo "$tool/bin" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
