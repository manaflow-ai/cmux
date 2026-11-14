#!/usr/bin/env bash
# Regression test for scripts/upload-sentry-dsyms.sh: a flaky Sentry upload
# (nightly runs 37531729976 and 37535932538 died on curl 28) is retried with
# backoff, and a Sentry outage warns instead of failing the nightly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/upload-sentry-dsyms.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake sentry-cli that fails its first $FAILS calls, counting each call.
cat > "$WORK/sentry-cli" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNT_FILE"
echo "args: $*" >> "$COUNT_FILE.args"
[ "$n" -gt "$FAILS" ]
FAKE
chmod +x "$WORK/sentry-cli"

run() {
  rm -f "$WORK/count" "$WORK/count.args"
  COUNT_FILE="$WORK/count" FAILS="$1" SENTRY_CLI="$WORK/sentry-cli" \
    SENTRY_UPLOAD_RETRY_DELAYS="0 0" SENTRY_AUTH_TOKEN=token \
    "$SCRIPT" "$WORK/dsyms" > "$WORK/out" 2>&1
}

run 2 || { echo "FAIL: an upload that succeeds on the third try must pass"; cat "$WORK/out"; exit 1; }
[ "$(cat "$WORK/count")" = 3 ] || { echo "FAIL: expected 3 upload attempts, saw $(cat "$WORK/count")"; exit 1; }
grep -q -- "debug-files upload --include-sources $WORK/dsyms" "$WORK/count.args" \
  || { echo "FAIL: the upload must pass --include-sources and the path"; cat "$WORK/count.args"; exit 1; }

run 99 || { echo "FAIL: a Sentry outage must not fail the nightly"; cat "$WORK/out"; exit 1; }
[ "$(cat "$WORK/count")" = 3 ] || { echo "FAIL: expected 3 attempts before giving up, saw $(cat "$WORK/count")"; exit 1; }
grep -q '^::warning' "$WORK/out" || { echo "FAIL: giving up must leave a ::warning annotation"; cat "$WORK/out"; exit 1; }

rm -f "$WORK/count"
COUNT_FILE="$WORK/count" FAILS=0 SENTRY_CLI="$WORK/sentry-cli" SENTRY_AUTH_TOKEN= "$SCRIPT" "$WORK/dsyms" > "$WORK/out" 2>&1 \
  || { echo "FAIL: no token must skip quietly"; exit 1; }
[ ! -e "$WORK/count" ] || { echo "FAIL: no token must not call sentry-cli"; exit 1; }

if ! awk '
  /^      - name: Upload dSYMs to Sentry/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /scripts\/upload-sentry-dsyms\.sh/ { saw=1 }
  END { exit !saw }
' "$ROOT_DIR/.github/workflows/nightly.yml"; then
  echo "FAIL: the nightly dSYM upload must go through scripts/upload-sentry-dsyms.sh"
  exit 1
fi

# nightly.yml's build-nightly-app holds no Sentry token: scripts/ci/collect-sentry-difs.py gathers
# what `sentry-cli debug-files upload --include-sources` reads there (Mach-O files with a debug id,
# whole dSYM bundles) and bundles their sources, which exist only on the build machine; the
# upload-nightly-dsyms job uploads both from Linux.
COLLECT="$ROOT_DIR/scripts/ci/collect-sentry-difs.py"
P="$WORK/products"
mkdir -p "$P/bin" "$P/Frameworks/F.framework/Versions/A" "$P/x.app.dSYM/Contents/Resources/DWARF" "$P/obj"
python3 - "$P" <<'PY'
import struct, sys
root = sys.argv[1]
def thin(filetype, uuid=True, big=False):
    order = ">" if big else "<"
    cmds = struct.pack(order + "II", 0x1b, 24) + bytes(range(16)) if uuid else struct.pack(order + "II", 0x19, 72) + bytes(64)
    return struct.pack(order + "IiiIIIII", 0xfeedfacf, 0x0100000c, 0, filetype, 1, len(cmds), 0, 0) + cmds
def write(path, data):
    with open(f"{root}/{path}", "wb") as out:
        out.write(data)
write("bin/tool", thin(2))
write("bin/big-endian", thin(6, big=True))
write("obj/Thing.o", thin(1, uuid=False))
first, second = thin(1, uuid=False), thin(6)
header = struct.pack(">II", 0xcafebabe, 2) + struct.pack(">iiIII", 0x01000007, 3, 4096, len(first), 12) \
    + struct.pack(">iiIII", 0x0100000c, 0, 8192, len(second), 14)
fat = bytearray(8192 + len(second))
fat[:len(header)] = header
fat[4096:4096 + len(first)] = first
fat[8192:] = second
write("Frameworks/F.framework/Versions/A/F", bytes(fat))
write("x.app.dSYM/Contents/Resources/DWARF/x", thin(10))
write("x.app.dSYM/Contents/Info.plist", b"<?xml version='1.0'?><plist/>")
write("README", b"not a binary")
write("Java.class", struct.pack(">II", 0xcafebabe, 52) + bytes(64))
write("truncated", struct.pack("<I", 0xfeedfacf))
PY
ln -s Versions/A/F "$P/Frameworks/F.framework/F"
cat > "$WORK/bundle-cli" <<'FAKE'
#!/usr/bin/env bash
# debug-files bundle-sources -o OUT PATH: a bundle for the dSYM only, a failure for "big-endian".
echo "$*" >> "$BUNDLE_LOG"
out="$4"; path="$5"
[[ "$(basename "$path")" == big-endian ]] && exit 1
[[ "$(basename "$path")" == x ]] || { echo "skipped $path (no files found)" >&2; exit 0; }
mkdir -p "$out" && echo sources > "$out/x.src.zip"
FAKE
chmod +x "$WORK/bundle-cli"
mkdir -p "$WORK/collected/stale"
BUNDLE_LOG="$WORK/bundle.log" python3 "$COLLECT" "$P" "$WORK/collected" --sentry-cli "$WORK/bundle-cli" > "$WORK/out" 2>&1 \
  || { echo "FAIL: collecting dSYMs must succeed"; cat "$WORK/out"; exit 1; }
got="$(cd "$WORK/collected/products" && find . \( -type f -o -type l \) | sort | tr '\n' ' ')"
want="./Frameworks/F.framework/Versions/A/F ./bin/big-endian ./bin/tool ./x.app.dSYM/Contents/Info.plist ./x.app.dSYM/Contents/Resources/DWARF/x "
[ "$got" = "$want" ] || { echo "FAIL: collected $got, expected $want"; exit 1; }
cmp -s "$P/bin/tool" "$WORK/collected/products/bin/tool" || { echo "FAIL: a collected file must be the same bytes"; exit 1; }
[ -s "$WORK/collected/sources/x.app.dSYM/Contents/Resources/DWARF/x/x.src.zip" ] \
  || { echo "FAIL: the dSYM's source bundle must be under sources/<its path>"; find "$WORK/collected"; exit 1; }
[ "$(find "$WORK/collected/sources" -type f | wc -l)" -eq 1 ] || { echo "FAIL: only files with sources leave a bundle"; exit 1; }
[ ! -e "$WORK/collected/stale" ] || { echo "FAIL: collecting must start from an empty folder"; exit 1; }
[ "$(wc -l < "$WORK/bundle.log")" -eq 4 ] || { echo "FAIL: bundle-sources must run once per collected Mach-O file"; cat "$WORK/bundle.log"; exit 1; }
grep -q -- "^debug-files bundle-sources -o $WORK/collected/sources/bin/tool $P/bin/tool$" "$WORK/bundle.log" \
  || { echo "FAIL: bundle-sources must read the original path (its sources resolve there)"; cat "$WORK/bundle.log"; exit 1; }
grep -q 'no source bundle for bin/big-endian' "$WORK/out" || { echo "FAIL: a failed source bundle must be logged"; cat "$WORK/out"; exit 1; }
grep -q '^::warning' "$WORK/out" && { echo "FAIL: one failed bundle among good ones is not a warning"; cat "$WORK/out"; exit 1; }
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/broken-cli"; chmod +x "$WORK/broken-cli"
python3 "$COLLECT" "$P" "$WORK/broken" --sentry-cli "$WORK/broken-cli" > "$WORK/out" 2>&1 \
  || { echo "FAIL: a broken sentry-cli must not fail the collection"; cat "$WORK/out"; exit 1; }
grep -q '^::warning' "$WORK/out" || { echo "FAIL: no source bundle at all must leave a warning"; cat "$WORK/out"; exit 1; }
python3 "$COLLECT" "$P" "$WORK/plain" > "$WORK/out" 2>&1 || { echo "FAIL: collecting without sentry-cli must succeed"; exit 1; }
[ -d "$WORK/plain/sources" ] && [ -z "$(ls -A "$WORK/plain/sources")" ] || { echo "FAIL: without sentry-cli, sources/ is empty"; exit 1; }
echo "PASS: the dSYM collector keeps what sentry-cli uploads and bundles sources where they exist"

if ! awk '
  /^      - name: Upload dSYMs to Sentry/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /SENTRY_AUTH_TOKEN/ { token=1 }
  in_step && /upload-sentry-dsyms\.sh "\$RUNNER_TEMP\/sentry-difs\/products" "\$RUNNER_TEMP\/sentry-difs\/sources"/ { both=1 }
  END { exit !(token && both) }
' "$ROOT_DIR/.github/workflows/nightly.yml"; then
  echo "FAIL: the nightly Sentry upload must send the collected files and their source bundles"
  exit 1
fi

echo "PASS: dSYM upload retries with backoff and never fails the nightly"
