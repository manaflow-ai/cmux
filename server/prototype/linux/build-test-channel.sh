#!/bin/sh
# Builds a throwaway signed test channel for the Linux installer prototype.
#
#   build-test-channel.sh <out-dir> [port]
#
# Output: <out-dir>/www (serve it with `python3 -m http.server --bind
# 127.0.0.1 <port> --directory <out-dir>/www`), <out-dir>/install.sh (the
# installer with its GENERATED block filled for this channel) and
# <out-dir>/keys (an Ed25519 keypair made for this prototype only; it signs
# nothing outside this directory).
#
# Packages: `cmux` is the real pinned cmux-tui (x86_64 musl) from its public
# commit-addressed URL; `cmux-host-run` is the unit-command stand-in; v2 adds
# the real `cmux-hook`.
#
# Manifests (sequence, purpose):
#   v/1        1  fresh install
#   v/2        2  upgrade (cmux-host-run 2, adds cmux-hook)
#   v/expired  3  expired an hour ago
#   v/badsig   4  signed with a key the installer does not trust
#   v/tampered 5  lists cmux-host-run 3, the served bytes differ by one byte
set -eu

out=${1:?usage: build-test-channel.sh <out-dir> [port]}
port=${2:-8765}
here=$(cd "$(dirname "$0")" && pwd)
base="http://127.0.0.1:$port"

# Pinned cmux-tui (scripts/cmux-next/cmux-tui.pin commit; manifest.json binaries).
tui_commit='f39636c811aaa7c0896fb270fd745ba1d53dfcca'
tui_url="https://files.cmux.com/cmux-tui/$tui_commit/cmux-tui-x86_64-unknown-linux-musl"
tui_sha='a327d2575480c2644c52640c4b633395df4a8bb48cc1b7d25292257f1f05f72f'
hook_url="https://files.cmux.com/cmux-tui/$tui_commit/cmux-tui-hook-x86_64-unknown-linux-musl"
hook_sha='2d0354658e55a77e433fd90b9e01371d9755cb0c8037ae51e30ce20852b4c5a7'

rm -rf "$out"
mkdir -p "$out/www/channel/v" "$out/www/pkg" "$out/www/bootstrap" "$out/keys" "$out/work/bin"
umask 022

fetch_pinned() {
  curl -fsSL --proto '=https' -o "$2" "$1"
  [ "$(sha256sum "$2" | awk '{print $1}')" = "$3" ] || { echo "pinned sha mismatch: $1" >&2; exit 1; }
}
fetch_pinned "$tui_url" "$out/work/cmux-tui" "$tui_sha"
fetch_pinned "$hook_url" "$out/work/cmux-hook" "$hook_sha"
tui_size=$(wc -c <"$out/work/cmux-tui" | tr -d ' ')
hook_size=$(wc -c <"$out/work/cmux-hook" | tr -d ' ')

# Keys: current and next are trusted by the installer; rogue is not. The
# private keys are created under umask 077 (0600 files in a 0700 directory).
(
  umask 077
  chmod 700 "$out/keys"
  for k in current next rogue; do
    openssl genpkey -algorithm ed25519 -out "$out/keys/$k.key" 2>/dev/null
  done
)
for k in current next rogue; do
  openssl pkey -in "$out/keys/$k.key" -pubout -outform DER 2>/dev/null | base64 -w0 >"$out/keys/$k.pub.b64"
done

# Bootstrap archive: bin/cmux.
cp "$out/work/cmux-tui" "$out/work/bin/cmux"
chmod 755 "$out/work/bin/cmux"
tar -C "$out/work" -czf "$out/www/bootstrap/cmux-x86_64-linux.tar.gz" bin/cmux
boot="$out/www/bootstrap/cmux-x86_64-linux.tar.gz"

# cmux-host-run packages 1, 2, 3 (3 is served tampered).
for v in 1 2 3; do
  d="$out/work/host-run-$v"
  mkdir -p "$d/bin"
  sed "s/@VERSION@/$v/" "$here/cmux-host-run" >"$d/bin/cmux-host-run"
  chmod 755 "$d/bin/cmux-host-run"
  tar -C "$d" -czf "$out/www/pkg/cmux-host-run-$v.tar.gz" bin/cmux-host-run
done
sha() { sha256sum "$1" | awk '{print $1}'; }
size() { wc -c <"$1" | tr -d ' '; }

pkg_line() { # name version url sha size kind [bin]
  if [ "$6" = bin ]; then
    printf '{"name":"%s","version":"%s","url":"%s","sha256":"%s","size":%s,"kind":"bin","bin":"%s","roles":"all"}' "$1" "$2" "$3" "$4" "$5" "$7"
  else
    printf '{"name":"%s","version":"%s","url":"%s","sha256":"%s","size":%s,"kind":"tar.gz","roles":"all"}' "$1" "$2" "$3" "$4" "$5"
  fi
}
cmux_line=$(pkg_line cmux "${tui_commit%"${tui_commit#???????}"}" "$tui_url" "$tui_sha" "$tui_size" bin cmux)
hook_line=$(pkg_line cmux-hook "${tui_commit%"${tui_commit#???????}"}" "$hook_url" "$hook_sha" "$hook_size" bin cmux-hook)
hr() { pkg_line cmux-host-run "$1" "$base/pkg/cmux-host-run-$1.tar.gz" "$(sha "$out/www/pkg/cmux-host-run-$1.tar.gz")" "$(size "$out/www/pkg/cmux-host-run-$1.tar.gz")" tar.gz; }

now=$(date +%s)
week=$((now + 7 * 86400))
manifest() { # file sequence version expires key package-lines...
  f=$1 seq=$2 ver=$3 exp=$4 key=$5
  shift 5
  {
    printf '{"schema":1,"channel":"test","sequence":%s,"version":"%s","expires":%s,"minCmux":"0","packages":[\n' "$seq" "$ver" "$exp"
    n=$#
    for line in "$@"; do
      n=$((n - 1))
      if [ "$n" -gt 0 ]; then printf '%s,\n' "$line"; else printf '%s\n' "$line"; fi
    done
    printf ']}\n'
  } >"$f"
  openssl pkeyutl -sign -inkey "$out/keys/$key.key" -rawin -in "$f" -out "$f.sig"
}
manifest "$out/www/channel/v/1.json" 1 1 "$week" current "$cmux_line" "$(hr 1)"
manifest "$out/www/channel/v/2.json" 2 2 "$week" next "$cmux_line" "$(hr 2)" "$hook_line"
manifest "$out/www/channel/v/expired.json" 3 expired "$((now - 3600))" current "$cmux_line" "$(hr 2)"
manifest "$out/www/channel/v/badsig.json" 4 badsig "$week" rogue "$cmux_line" "$(hr 2)"
manifest "$out/www/channel/v/tampered.json" 5 tampered "$week" current "$cmux_line" "$(hr 3)"
cp "$out/www/channel/v/1.json" "$out/www/channel/latest.json"
cp "$out/www/channel/v/1.json.sig" "$out/www/channel/latest.json.sig"
# Tamper: flip the last byte of the served cmux-host-run 3 (same size).
python3 - "$out/www/pkg/cmux-host-run-3.tar.gz" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
b[-1] ^= 0xFF
open(p, "wb").write(bytes(b))
PY

# Installer with the GENERATED block for this channel.
awk -v ver="test-$now" -v chan="$base/channel" \
  -v kc="$(cat "$out/keys/current.pub.b64")" -v kn="$(cat "$out/keys/next.pub.b64")" \
  -v burl="$base/bootstrap/cmux-x86_64-linux.tar.gz" -v bsize="$(size "$boot")" -v bsha="$(sha "$boot")" '
  /^# --- BEGIN GENERATED/ { print; skip = 1
    printf "CMUX_RELEASE_VERSION=%c%s%c\n", 39, ver, 39
    printf "CMUX_CHANNEL_URL=%c%s%c\n", 39, chan, 39
    printf "CMUX_PUBKEY_CURRENT=%c%s%c\n", 39, kc, 39
    printf "CMUX_PUBKEY_NEXT=%c%s%c\n", 39, kn, 39
    printf "CMUX_BOOTSTRAP_X86_64_LINUX_URL=%c%s%c\n", 39, burl, 39
    printf "CMUX_BOOTSTRAP_X86_64_LINUX_SIZE=%c%s%c\n", 39, bsize, 39
    printf "CMUX_BOOTSTRAP_X86_64_LINUX_SHA256=%c%s%c\n", 39, bsha, 39
    printf "CMUX_BOOTSTRAP_AARCH64_LINUX_URL=%c%c\n", 39, 39
    printf "CMUX_BOOTSTRAP_AARCH64_LINUX_SIZE=%c0%c\n", 39, 39
    printf "CMUX_BOOTSTRAP_AARCH64_LINUX_SHA256=%c%c\n", 39, 39
    printf "CMUX_TEST_CHANNEL=%c1%c\n", 39, 39
    next }
  /^# --- END GENERATED/ { skip = 0 }
  !skip { print }' "$here/install.sh" >"$out/install.sh"
chmod 755 "$out/install.sh"
cp "$out/install.sh" "$out/www/install.sh"
sha "$out/install.sh" >"$out/www/install.sh.sha256"
openssl pkeyutl -sign -inkey "$out/keys/current.key" -rawin -in "$out/install.sh" -out "$out/www/install.sh.sig"
rm -rf "$out/work"
echo "test channel ready: $out (serve $out/www on $base)"
ls -l "$out/www/channel/v" "$out/www/pkg" "$out/www/bootstrap"
