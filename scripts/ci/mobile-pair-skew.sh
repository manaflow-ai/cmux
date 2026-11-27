#!/usr/bin/env bash
# Phone vs Mac skew: this head's iPhone link dials the Mac host an older build ships.
#
# The phone and the Mac never update together. TestFlight carries this head's link
# (cmux-mobile-link) while Leo's Mac runs whatever NIGHTLY it last relaunched into,
# often a day and 1000+ commits older. tests/pair_matrix_ios_mac.rs builds both
# sides at one commit, so a change that breaks an older Mac host passes it. Leo,
# 11-27: "i mean we cant connect to phone anyways right now lol".
#
# This builds cmux-mobile-host and cmux-mobile-stub-tui from OLD_CHECKOUT (CI: the
# commit the NEXT nightly was built from), and cmux-mobile-dial and the fake backend
# from HEAD_CHECKOUT, runs them on loopback, and dials with every transport. It fails
# unless each transport links and the daemon channel answers `identify`.
#
#   scripts/ci/mobile-pair-skew.sh OLD_CHECKOUT [HEAD_CHECKOUT]
#
# The CI job runs this twice: first with the NIGHTLY tree as OLD_CHECKOUT, then
# with the PR tree as OLD_CHECKOUT, so both host/dial directions cross the skew.
set -euo pipefail

old=$(cd "${1:?usage: mobile-pair-skew.sh OLD_CHECKOUT [HEAD_CHECKOUT]}" && pwd)
head=$(cd "${2:-.}" && pwd)
work=$(mktemp -d)
target=${CARGO_TARGET_DIR:-$work/target}
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [[ -n "${SKEW_LOG_DIR:-}" ]]; then mkdir -p "$SKEW_LOG_DIR"; cp "$work"/*.log "$work"/dial.* "$SKEW_LOG_DIR"/ 2>/dev/null || true; fi
  rm -rf "$work/bin" "$work/tui" "$work/state"
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/tui" "$work/state"

echo "old (Mac host): $(git -C "$old" rev-parse HEAD)"
echo "head (phone link): $(git -C "$head" rev-parse HEAD)"

# One target dir: the two trees share most dependencies, so the second build is mostly cached.
(cd "$old/cmux-next-ios/rust" && CARGO_TARGET_DIR=$target cargo build --release -p cmux-mobile-host \
  --bin cmux-mobile-host --bin cmux-mobile-stub-tui)
cp "$target/release/cmux-mobile-host" "$target/release/cmux-mobile-stub-tui" "$work/bin/"
(cd "$head/cmux-next-ios/rust" && CARGO_TARGET_DIR=$target cargo build --release -p cmux-mobile-host \
  --features fake-backend --bin cmux-mobile-dial --bin cmux-mobile-fake-backend)
cp "$target/release/cmux-mobile-dial" "$target/release/cmux-mobile-fake-backend" "$work/bin/"

port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
url="http://127.0.0.1:$port"
printf 'user:u1' > "$work/token"

"$work/bin/cmux-mobile-fake-backend" "127.0.0.1:$port" > "$work/backend.log" 2>&1 & pids+=($!)
"$work/bin/cmux-mobile-stub-tui" "$work/tui" main > "$work/tui.log" 2>&1 & pids+=($!)
for _ in $(seq 50); do
  [[ -S "$work/tui/main.sock" ]] && curl -s -o /dev/null "$url/v1/ice" && break
  sleep 0.2
done
CMUX_MOBILE_BASE_URL=$url CMUX_MOBILE_TEAM_ID=t1 CMUX_MOBILE_DEVICE_ID=mac1 \
  CMUX_MOBILE_ACCESS_TOKEN=user:u1 CMUX_MOBILE_OWNER_USER_ID=u1 CMUX_MOBILE_STATE_DIR="$work/state" \
  CMUX_MOBILE_TUI_SOCKET_DIR="$work/tui" CMUX_MOBILE_TUI_SOCKET="$work/tui/main.sock" \
  CMUX_MOBILE_INCLUDE_LOOPBACK=1 CMUX_MOBILE_ACPMUX_URL=ws://127.0.0.1:1/none \
  "$work/bin/cmux-mobile-host" > "$work/host.log" 2>&1 & pids+=($!)
for _ in $(seq 100); do grep -q 'signaling connected' "$work/host.log" && break; sleep 0.2; done
if ! grep -q 'signaling connected' "$work/host.log"; then
  echo "::error::the old Mac host never connected to signaling"; tail -40 "$work/host.log"; exit 1
fi

status=0
bash "$(dirname "${BASH_SOURCE[0]}")/timeout.sh" 120 "$work/bin/cmux-mobile-dial" --base-url "$url" --token-file "$work/token" --team t1 --mac mac1 \
  --transport webrtc --transport wireguard --daemon > "$work/dial.out" 2> "$work/dial.err" || status=$?
if ! python3 -I - "$work/dial.out" "$status" <<'EOF'
import json, sys
path, status = sys.argv[1], int(sys.argv[2])
want, bad, seen = {"webrtc", "wireguard"}, [], set()
for line in open(path):
    line = line.strip()
    if not line.startswith("{"):
        continue
    row = json.loads(line)
    t = row.get("transport")
    seen.add(t)
    answers = [json.loads(a) for a in (row.get("daemon") or "").splitlines() if a.strip()]
    identify = next((a for a in answers if a.get("id") == 1), None)
    if not (identify and identify.get("ok")):
        bad.append(f"{t}: daemon identify did not answer ok: {row.get('daemon') or row.get('error')}")
    else:
        print(f"ok {t}: path {row.get('path')}, link up in {row.get('connect_ms')} ms, identify ok")
for t in sorted(want - seen):
    bad.append(f"{t}: no link (dial exit {status})")
for b in bad:
    print(f"::error::{b}")
sys.exit(1 if bad else 0)
EOF
then
  echo "--- dial stderr"; tail -40 "$work/dial.err"
  echo "--- old host log"; tail -60 "$work/host.log"
  exit 1
fi
