#!/usr/bin/env bash
# r2-cache.sh restore: a restore killed mid-unpack (a step's timeout-minutes) leaves the directory as it
# was, never half a cache (machine channel run 46003645716 built against half a cargo target and failed);
# the next restore sweeps the staging directory it left and lands whole. A fake curl serves the bucket.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../r2-cache.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/bucket" "$tmp/src/deps"
cat > "$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Serves "$FAKE_BUCKET/<last path segment>" for -o; anything else is a miss (curl --fail's 22).
out="" url=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift ;;
    --retry|--retry-delay|--connect-timeout|--max-time) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
f="$FAKE_BUCKET/${url##*/}"
[[ -n "$out" && -f "$f" ]] || exit 22
cp "$f" "$out"
FAKE
# A tar that unpacks the first member, then hangs until killed: a restore cut off by its step timeout.
cat > "$tmp/slowbin-tar" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${FAKE_TAR_HANG:-}" ]]; then
  for a in "$@"; do [[ "$prev" == -C ]] && into="$a"; prev="$a"; done
  : > "$into/half-written"
  : > "$FAKE_TAR_HANG"
  exec sleep 600
fi
# Hold the unpack until the gate opens: a restore whose step is killed meanwhile, the script running on.
if [[ -n "${FAKE_TAR_GATE:-}" ]]; then
  : > "$FAKE_TAR_GATE.waiting"
  while [[ ! -e "$FAKE_TAR_GATE" ]]; do sleep 0.1; done
fi
exec "$REAL_TAR" "$@"
FAKE
mkdir -p "$tmp/slowbin"; mv "$tmp/slowbin-tar" "$tmp/slowbin/tar"
chmod +x "$tmp/bin/curl" "$tmp/slowbin/tar"

REAL_TAR="$(command -v tar)"; export REAL_TAR
export PATH="$tmp/slowbin:$tmp/bin:$PATH" FAKE_BUCKET="$tmp/bucket" RUNNER_OS=Linux RUNNER_ARCH=X64
export CI_CACHE_R2_PUBLIC_URL=https://pub.example
unset GITHUB_OUTPUT CMUX_LAN_CACHE_SOCKET || true
export CMUX_LAN_CACHE_SOCKET="$tmp/no-socket"

head -c 100000 /dev/urandom > "$tmp/src/deps/libserde.rmeta"
"$REAL_TAR" -czf "$tmp/bucket/k1.tar.gz" -C "$tmp/src" .

# 1. Killed mid-unpack: the directory keeps what it had, and nothing half-written lands in it.
mkdir -p "$tmp/target"; echo before > "$tmp/target/sentinel"
FAKE_TAR_HANG="$tmp/hung" setsid bash "$script" restore "$tmp/target" k1 > "$tmp/out1" 2>&1 &
pid=$!
for _ in $(seq 1 100); do [[ -f "$tmp/hung" ]] && break; sleep 0.1; done
[[ -f "$tmp/hung" ]] || { cat "$tmp/out1"; echo "FAIL: the fake tar never started"; exit 1; }
kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid"
wait "$pid" 2>/dev/null || true
[[ "$(cat "$tmp/target/sentinel")" == before ]] || { echo "FAIL: the killed restore changed the directory"; exit 1; }
[[ ! -e "$tmp/target/half-written" ]] || { echo "FAIL: half a cache landed in the directory"; exit 1; }
ls -d "$tmp"/target.r2-restoring.* > /dev/null 2>&1 || { echo "FAIL: expected the killed restore's staging directory"; exit 1; }

# 2. The next restore sweeps that staging directory and lands the whole archive in place of the old one.
bash "$script" restore "$tmp/target" k1 > "$tmp/out2" 2>&1
grep -q 'r2-cache: restored k1' "$tmp/out2" || { cat "$tmp/out2"; echo "FAIL: restore"; exit 1; }
cmp -s "$tmp/src/deps/libserde.rmeta" "$tmp/target/deps/libserde.rmeta" || { echo "FAIL: restored bytes differ"; exit 1; }
[[ ! -e "$tmp/target/sentinel" ]] || { echo "FAIL: the old contents survived the restore"; exit 1; }
! ls -d "$tmp"/target.r2-restoring.* > /dev/null 2>&1 || { echo "FAIL: a staging directory was left behind"; exit 1; }

# 3. A corrupt archive is a miss and leaves the directory as it was.
echo keep > "$tmp/target/sentinel"
head -c 1000 /dev/urandom > "$tmp/bucket/k2.tar.gz"
bash "$script" restore "$tmp/target" k2 > "$tmp/out3" 2>&1
grep -q 'could not unpack k2.tar.gz' "$tmp/out3" || { cat "$tmp/out3"; echo "FAIL: expected an unpack failure"; exit 1; }
[[ "$(cat "$tmp/target/sentinel")" == keep ]] || { echo "FAIL: a corrupt archive changed the directory"; exit 1; }
! ls -d "$tmp"/target.r2-restoring.* > /dev/null 2>&1 || { echo "FAIL: the corrupt archive's staging directory was left behind"; exit 1; }

# 4. The step's shell killed by its timeout-minutes while this script, its child, keeps unpacking: the
# job's next step is already building in the directory, so the orphan must not swap a cache in under it
# (batch run 46058976708: cargo "failed to write .../target/debug/.fingerprint/..." ~2 min after the
# restore step timed out).
echo building > "$tmp/target/sentinel"
gate="$tmp/gate"
FAKE_TAR_GATE="$gate" bash -c 'bash "$1" restore "$2" k1 > "$3" 2>&1 & echo $! > "$4"; wait' _ \
  "$script" "$tmp/target" "$tmp/out4" "$tmp/child4" &
step=$!
for _ in $(seq 1 100); do [[ -f "$gate.waiting" ]] && break; sleep 0.1; done
[[ -f "$gate.waiting" ]] || { cat "$tmp/out4"; echo "FAIL: the gated tar never started"; exit 1; }
kill -KILL "$step"; wait "$step" 2>/dev/null || true
child="$(cat "$tmp/child4")"
: > "$gate"
for _ in $(seq 1 100); do kill -0 "$child" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$child" 2>/dev/null || { echo "FAIL: the orphaned restore did not finish"; exit 1; }
grep -q 'step ended before k1' "$tmp/out4" || { cat "$tmp/out4"; echo "FAIL: expected the orphan to stand down"; exit 1; }
[[ "$(cat "$tmp/target/sentinel")" == building ]] || { echo "FAIL: the orphaned restore swapped the directory"; exit 1; }
! ls -d "$tmp"/target.r2-restoring.* > /dev/null 2>&1 || { echo "FAIL: the orphan left its staging directory"; exit 1; }

echo PASS
