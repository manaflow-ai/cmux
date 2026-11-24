#!/usr/bin/env bash
# The link relay's round trip between two hosts, with the relay placed the old way (the joiner's locationHint)
# and from both ends (PROTOCOL.md "Relay placement"), on one Worker deploy
# (cmux-next-ios/rust/crates/cmux-mobile-host/src/bin/cmux-mobile-relay-rtt.rs, its header says how):
#   scripts/measure/relay-rtt-probe.sh mac   --mac UUID [PROBE_ARGS...]     on host B (echoes; --seconds 1800)
#   scripts/measure/relay-rtt-probe.sh phone --mac UUID [PROBE_ARGS...]     on host A (--trials 3 --samples 200)
# Both with the same account and the same --mac (pick one: `uuidgen`). The phone waits for the Mac to come
# online, so the two can start in any order. OUT_DIR ($RELAY_RTT_OUT, else $FAST_CHECKS_OUT, else a temp dir)
# gets relay-rtt.json and relay-rtt.md; the phone prints RELAY-RTT lines per trial.
#
# Account: CMUX_MOBILE_PROBE_TOKEN_FILE (a Stack access token of the dev project), or CMUX_MOBILE_PROBE_TOKEN
# (the token itself, for a CI host), else with CMUX_MOBILE_PROBE_SIGNUP=1 a new throwaway account of the DEV
# Stack project; its token is written to $OUT_DIR/token (mode 600) so the other host can use the same account.
# CMUX_MOBILE_PROBE_BIN skips the build and runs that binary.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
role="${1:?usage: relay-rtt-probe.sh phone|mac --mac UUID [args]}"
shift
out="${RELAY_RTT_OUT:-${FAST_CHECKS_OUT:-}}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
[ -n "$out" ] || out="$work/out"
mkdir -p "$out"

bin="${CMUX_MOBILE_PROBE_BIN:-}"
if [ -z "$bin" ]; then
  (cd "$root/cmux-next-ios/rust" && cargo build --release --locked -q -p cmux-mobile-host --bin cmux-mobile-relay-rtt)
  bin="${CARGO_TARGET_DIR:-$root/cmux-next-ios/rust/target}/release/cmux-mobile-relay-rtt"
fi

umask 077
token="${CMUX_MOBILE_PROBE_TOKEN_FILE:-}"
if [ -z "$token" ] && [ -n "${CMUX_MOBILE_PROBE_TOKEN:-}" ]; then
  printf '%s' "$CMUX_MOBILE_PROBE_TOKEN" > "$work/token"
  token="$work/token"
fi
if [ -z "$token" ]; then
  if [ "${CMUX_MOBILE_PROBE_SIGNUP:-0}" != 1 ]; then
    echo "relay-rtt-probe: set CMUX_MOBILE_PROBE_TOKEN_FILE or CMUX_MOBILE_PROBE_TOKEN, or CMUX_MOBILE_PROBE_SIGNUP=1" >&2
    exit 2
  fi
  # The dev Stack project and its public client key (cmux-next-ios/backend/wrangler.jsonc STACK_PROJECTS).
  project=454ecd03-1db2-4050-845e-4ce5b0cd9895
  key=pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g
  password="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
  printf '{"email":"relay-rtt-probe-%s-%s@example.com","password":"%s"}' "$(date +%s)" "$RANDOM" "$password" > "$work/signup.json"
  curl -fsS -X POST https://api.stack-auth.com/api/v1/auth/password/sign-up \
    -H 'content-type: application/json' -H "x-stack-project-id: $project" \
    -H "x-stack-publishable-client-key: $key" -H 'x-stack-access-type: client' \
    --data-binary "@$work/signup.json" -o "$work/session.json"
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$work/session.json" > "$out/token"
  token="$out/token"
  echo "relay-rtt-probe: throwaway dev account; its token (valid 1 h) is $out/token" >&2
fi

"$bin" --token-file "$token" --role "$role" --out "$out" "$@" | tee "$out/stdout.txt"
cat "$out/relay-rtt.md" 2>/dev/null || true
