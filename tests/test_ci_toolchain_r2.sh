#!/usr/bin/env bash
# scripts/ci/toolchain-r2.sh restore puts the pinned Node, Bun and Rust where setup-node, setup-bun and rustup
# look first, from the CI cache bucket, on a Freestyle runner only; every miss, bad copy or odd runner leaves
# the real installer to run. Same shape as test_ci_zig_tarball_r2.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/toolchain-r2.sh"
TMP="$(mktemp -d)"
server_pid=""
cleanup() { [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || { echo "SKIP toolchain-r2 (Linux only)"; exit 0; }
case "$(uname -m)" in x86_64) na=x64 ba=x64 triple=x86_64-unknown-linux-gnu ;; aarch64) na=arm64 ba=aarch64 triple=aarch64-unknown-linux-gnu ;; *) echo "SKIP"; exit 0 ;; esac
ns="Linux-X64"

# A fake bucket holding node 9.9.9, bun 8.8.8 and Rust 7.7.7, with a pins file for the first two.
bucket="$TMP/bucket/v1/$ns/objects"; mkdir -p "$bucket" "$TMP/n/node-v9.9.9-linux-$na/bin" "$TMP/b/bun-linux-$ba"
printf '#!/bin/sh\necho v9.9.9\n' > "$TMP/n/node-v9.9.9-linux-$na/bin/node"; chmod +x "$TMP/n/node-v9.9.9-linux-$na/bin/node"
printf '#!/bin/sh\necho 8.8.8\n' > "$TMP/b/bun-linux-$ba/bun"; chmod +x "$TMP/b/bun-linux-$ba/bun"
nname="node-v9.9.9-linux-$na.tar.gz"; bname="bun-v8.8.8-linux-$ba.zip"
tar -czf "$TMP/$nname" -C "$TMP/n" "node-v9.9.9-linux-$na"
(cd "$TMP/b" && python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2]); z.close()' "$TMP/$bname" "bun-linux-$ba/bun")
nsum="$(sha256sum "$TMP/$nname" | cut -d' ' -f1)"; bsum="$(sha256sum "$TMP/$bname" | cut -d' ' -f1)"
printf '# test pins\n%s  %s\n%s  %s\n' "$nsum" "$nname" "$bsum" "$bname" > "$TMP/pins"
put() { # NAME SUM FILE
  mkdir -p "$TMP/o/$1"; cp "$3" "$TMP/o/$1/$(basename "$3")"; tar -czf "$bucket/toolchain-$1-${2:0:16}.tar.gz" -C "$TMP/o/$1" .
}
put "$nname" "$nsum" "$TMP/$nname"; put "$bname" "$bsum" "$TMP/$bname"
cat > "$TMP/rust-toolchain.toml" <<TOML
[toolchain]
channel = "7.7.7"
profile = "minimal"
components = ["clippy", "rustfmt"]
TOML
rname="7.7.7-$triple"; rkey="toolchain-rust-$rname-minimal-clippy-rustfmt-v1"
mkdir -p "$TMP/r/toolchains/$rname/bin" "$TMP/r/update-hashes" "$TMP/r/cargo-bin"
printf '#!/bin/sh\necho "rustc 7.7.7 (fake)"\n' > "$TMP/r/toolchains/$rname/bin/rustc"; chmod +x "$TMP/r/toolchains/$rname/bin/rustc"
echo hash > "$TMP/r/update-hashes/$rname"; printf '#!/bin/sh\n' > "$TMP/r/cargo-bin/rustup"; chmod +x "$TMP/r/cargo-bin/rustup"; ln -s rustup "$TMP/r/cargo-bin/cargo"
tar -czf "$bucket/$rkey.tar.gz" -C "$TMP/r" .

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$TMP/bucket" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
export RUNNER_OS=Linux RUNNER_ARCH=X64 CMUX_LAN_CACHE_SOCKET="$TMP/none.sock" TOOLCHAIN_PINS_FILE="$TMP/pins"
export TOOLCHAIN_R2_URL="http://127.0.0.1:$port" HOME="$TMP/home"; mkdir -p "$HOME"
export RUNNER_TOOL_CACHE="$TMP/tool" RUNNER_NAME=fsr-1-test-j1
# no real rustup on this PATH: the restore must bring its own
export PATH="/usr/bin:/bin"; command -v rustup >/dev/null 2>&1 && fail "this machine has rustup on /usr/bin; the test needs it absent"

# node: a hit lands in the tool cache with .complete, and setup-node's version check passes.
out="$(bash "$SCRIPT" restore node 9.9.9)"
[[ -f "$TMP/tool/node/9.9.9/$na.complete" && "$("$TMP/tool/node/9.9.9/$na/bin/node" --version)" == v9.9.9 ]] || fail "node not restored: $out"
grep -q "sha256 matches the pin" <<<"$out" || fail "node restore did not say it verified: $out"
out="$(bash "$SCRIPT" restore node 9.9.9)"; grep -q "is in the tool cache" <<<"$out" || fail "second node restore refetched: $out"

# bun: a hit installs ~/.bun/bin/bun.
bash "$SCRIPT" restore bun 8.8.8 >/dev/null
[[ "$("$HOME/.bun/bin/bun" --version)" == 8.8.8 ]] || fail "bun not restored"

# A copy that does not match its pin is discarded and nothing is installed.
echo tampered > "$TMP/o/$nname/$nname"; tar -czf "$bucket/toolchain-$nname-${nsum:0:16}.tar.gz" -C "$TMP/o/$nname" .
rm -rf "$TMP/tool"
out="$(bash "$SCRIPT" restore node 9.9.9)" || fail "a bad copy failed the step"
[[ ! -e "$TMP/tool/node/9.9.9/$na.complete" ]] || fail "a copy that does not match its pin was installed"
grep -q "does not match its pin" <<<"$out" || fail "a bad copy did not say so: $out"

# A version with no pin, a miss, an unreachable bucket and an empty URL leave the installer to run, exit 0.
bash "$SCRIPT" restore node 1.2.3 | grep -q "no pin" || fail "an unpinned version was not left alone"
bash "$SCRIPT" restore bun 8.8.9 | grep -q "no pin" || fail "an unpinned bun was not left alone"
TOOLCHAIN_R2_URL="http://127.0.0.1:1" bash "$SCRIPT" restore node 9.9.9 >/dev/null || fail "an unreachable bucket failed the step"
TOOLCHAIN_R2_URL='' bash "$SCRIPT" restore node 9.9.9 | grep -q "no cache URL" || fail "an empty URL did not turn it off"

# Not a Freestyle runner: nothing happens.
rm -rf "$TMP/tool"
RUNNER_NAME=cmux-linux-1 bash "$SCRIPT" restore node 9.9.9 | grep -q "not a Freestyle runner" || fail "an owned runner was touched"
[[ ! -e "$TMP/tool" ]] || fail "an owned runner got a node"

# rust: the toolchain and its update hash go into RUSTUP_HOME and rustup arrives when none is installed.
export RUSTUP_HOME="$TMP/rustup"
out="$(bash "$SCRIPT" restore rust "$TMP/rust-toolchain.toml")"
[[ -x "$RUSTUP_HOME/toolchains/$rname/bin/rustc" && -f "$RUSTUP_HOME/update-hashes/$rname" && -x "$HOME/.cargo/bin/rustup" && -L "$HOME/.cargo/bin/cargo" ]] || fail "rust not restored: $out"
out="$(bash "$SCRIPT" restore rust "$TMP/rust-toolchain.toml")"; grep -q "is installed" <<<"$out" || fail "second rust restore refetched: $out"
# A cached toolchain that reports another version is discarded.
sed -i 's/7.7.7/7.7.8/' "$TMP/r/toolchains/$rname/bin/rustc"; tar -czf "$bucket/$rkey.tar.gz" -C "$TMP/r" .
rm -rf "$RUSTUP_HOME"
bash "$SCRIPT" restore rust "$TMP/rust-toolchain.toml" | grep -q "does not run as Rust 7.7.7" || fail "a wrong-version toolchain was not discarded"
[[ ! -e "$RUSTUP_HOME/toolchains/$rname" ]] || fail "a wrong-version toolchain was installed"

# seed refuses without write credentials once the bucket lacks the key; exits at once when it holds it.
if env -u AWS_ACCESS_KEY_ID RUNNER_ARCH=ARM64 bash "$SCRIPT" seed node 9.9.9 2>/dev/null; then fail "seed ran without credentials"; fi
bash "$SCRIPT" seed node 9.9.9 2>/dev/null && fail "seed without credentials passed" || true
AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x CI_CACHE_R2_ENDPOINT=x CI_CACHE_R2_BUCKET=x bash "$SCRIPT" seed node 9.9.9 | grep -q "already holds" || fail "seed did not see the held key"

# The real pins file covers every exact Node and Bun version the workflows set up, and the wiring is in place.
python3 -I "$ROOT/tests/check_toolchain_r2_wiring.py" || fail "toolchain wiring"
echo "PASS toolchain-r2"
