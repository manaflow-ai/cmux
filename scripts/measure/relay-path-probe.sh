#!/usr/bin/env bash
# Every path the cmux NEXT iPhone link can take to a Mac, measured from this host
# (cmux-next-ios/rust/crates/cmux-mobile-host/src/bin/cmux-mobile-path-probe.rs):
#   scripts/measure/relay-path-probe.sh [OUT_DIR] [-- PROBE_ARGS...]
# Per path (wg-auto, wg-relay = TURN/UDP, wg-tls = TURN/TLS 443, webrtc-auto, webrtc-relay): setup p50/p95
# over N dials, link ping RTT p50/p95/p99 and loss; beside them GET /v1/ice, signaling open and WS RTT, the
# team hub's colos, one TURN allocation per transport, STUN RTT to the TURN server. Writes
# OUT_DIR/path-probe.json and path-probe.md (OUT_DIR defaults to $FAST_CHECKS_OUT, else a temp dir) and
# prints RELAY-PATH-PROBE lines.
#
# Account: CMUX_MOBILE_PROBE_TOKEN_FILE (a Stack access token of the dev project, mode 600), else with
# CMUX_MOBILE_PROBE_SIGNUP=1 a new throwaway account of the DEV Stack project is made for the run (dev only;
# it owns nothing but its own empty personal team). Base URL: the dev Worker unless PROBE_ARGS has
# --base-url. CMUX_MOBILE_PROBE_BIN skips the build and runs that binary.
#
# Both ends run here by default (a Mac-role device in the same process). A region pair: on host B
#   relay-path-probe.sh OUT -- --role mac --mac-seconds 900        (prints {"role":"mac","device":ID})
# and on host A, with the same account's token,
#   relay-path-probe.sh OUT -- --role phone --mac ID --site-a A:LAT,LON --site-b B:LAT,LON
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:-${FAST_CHECKS_OUT:-}}"
[ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
[ -n "$out" ] || out="$work/out"
mkdir -p "$out"

bin="${CMUX_MOBILE_PROBE_BIN:-}"
if [ -z "$bin" ]; then
  (cd "$root/cmux-next-ios/rust" && cargo build --release --locked -q -p cmux-mobile-host --bin cmux-mobile-path-probe)
  bin="$root/cmux-next-ios/rust/target/release/cmux-mobile-path-probe"
fi

token="${CMUX_MOBILE_PROBE_TOKEN_FILE:-}"
if [ -z "$token" ]; then
  if [ "${CMUX_MOBILE_PROBE_SIGNUP:-0}" != 1 ]; then
    echo "relay-path-probe: set CMUX_MOBILE_PROBE_TOKEN_FILE, or CMUX_MOBILE_PROBE_SIGNUP=1 for a throwaway dev account" >&2
    exit 2
  fi
  # The dev Stack project and its public client key (cmux-next-ios/backend/wrangler.jsonc STACK_PROJECTS).
  project=454ecd03-1db2-4050-845e-4ce5b0cd9895
  key=pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g
  password="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
  umask 077
  printf '{"email":"relay-path-probe-%s-%s@example.com","password":"%s"}' "$(date +%s)" "$RANDOM" "$password" > "$work/signup.json"
  curl -fsS -X POST https://api.stack-auth.com/api/v1/auth/password/sign-up \
    -H 'content-type: application/json' -H "x-stack-project-id: $project" \
    -H "x-stack-publishable-client-key: $key" -H 'x-stack-access-type: client' \
    --data-binary "@$work/signup.json" -o "$work/session.json"
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$work/session.json" > "$work/token"
  token="$work/token"
fi

"$bin" --token-file "$token" --out "$out" "$@" > "$out/stdout.json"
python3 -I - "$out/path-probe.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except FileNotFoundError:
    sys.exit(0)  # --role mac writes no report
hub = d.get("team_hub", {})
print(f"RELAY-PATH-PROBE host={d['host']} mode={d['mode']!r} hub={hub.get('hubColo')} ingress={hub.get('ingressColo')}")
for p in d["paths"]:
    s, r = p["setup_ms"], p["rtt_ms"]
    print(f"RELAY-PATH-PROBE path={p['name']} reported={p['reported_paths']} setup_p50={s['p50']} setup_p95={s['p95']} "
          f"rtt_p50={r['p50']} rtt_p95={r['p95']} rtt_p99={r['p99']} loss={r['loss_pct']}% errors={len(p['errors'])}")
PY
cat "$out/path-probe.md" 2>/dev/null || true
