#!/usr/bin/env bash
# launch-ready.sh keys=1: LR-KEYS SIDE MEDIAN N/M is the side's median first_key_ms over its measured launches and how
# many of them sent a message holding a key (launch-ready-summary.py --keys 1, the flag main passes); without keys=1
# the summary prints no LR-KEYS. A keys=1 measured launch's probe types (keys) and opens no terminal, even with
# state=bare; its other launches neither type nor open one. keys=1 takes front=home but not front=tab.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# shellcheck source=../launch-ready.sh
source "$here/launch-ready.sh"

fail() { echo "launch-ready keys: $*" >&2; exit 1; }

# head: three measured launches, two whose message held keys (first_key_ms 900 and 1100); base: one, none held.
{
  echo '{"side":"head","label":"prime","window_on_screen":500,"marks":{},"first_key_ms":null,"keys_landed":0}'
  echo '{"side":"head","label":"run1","window_on_screen":500,"marks":{},"first_key_ms":900,"keys_sent":12,"keys_landed":8,"keys_text":"efghijkl"}'
  echo '{"side":"head","label":"run2","window_on_screen":510,"marks":{},"first_key_ms":null,"keys_sent":36,"keys_landed":0,"keys_text":null}'
  echo '{"side":"head","label":"run3","window_on_screen":520,"marks":{},"first_key_ms":1100,"keys_sent":15,"keys_landed":3,"keys_text":"mno"}'
  echo '{"side":"base","label":"run1","window_on_screen":600,"marks":{},"first_key_ms":null,"keys_sent":36,"keys_landed":0,"keys_text":null}'
} >"$root/runs.jsonl"

out="$(python3 -I "$here/launch-ready-summary.py" "$root/runs.jsonl" --state kept --keys 1)"
grep -qx 'LR-KEYS head 1000.0 2/3' <<<"$out" || fail "head: want 'LR-KEYS head 1000.0 2/3' in: $out"
grep -qx 'LR-KEYS base None 0/1' <<<"$out" || fail "base: want 'LR-KEYS base None 0/1' in: $out"
echo 'launch-ready keys: LR-KEYS prints the median first key and the launches that kept one'

out="$(python3 -I "$here/launch-ready-summary.py" "$root/runs.jsonl" --state kept --keys 0)"
grep -q '^LR-KEYS' <<<"$out" && fail "keys=0 printed LR-KEYS: $out"
grep -q '^LR-USABLE head' <<<"$out" || fail "keys=0 lost LR-USABLE: $out"
echo 'launch-ready keys: no LR-KEYS without keys=1'

LR_STATE=bare LR_KEYS=1
[[ "$(probe_mode run1)" == keys ]] || fail "keys=1 run1: want keys, got '$(probe_mode run1)'"
[[ -z "$(probe_mode prime)" ]] || fail "keys=1 prime: want nothing, got '$(probe_mode prime)'"
LR_KEYS=0
[[ "$(probe_mode run1)" == shell ]] || fail "state=bare keys=0 run1: want shell"
LR_STATE=kept
[[ -z "$(probe_mode run1)" ]] || fail "state=kept keys=0 run1: want nothing"
echo 'launch-ready keys: only a keys=1 measured launch types, and it opens no terminal'

ok() { LR_STATE="$1" LR_CASE="" LR_DAEMON=warm LR_SNAPSHOT=own LR_FRONT="$2" LR_KEYS="$3" case_args_ok "" small 2>/dev/null; }
ok kept home 1 || fail "keys=1 front=home refused"
ok kept "" 1 || fail "keys=1 refused"
ok bare "" 1 || fail "state=bare keys=1 refused"
ok kept tab 0 || fail "front=tab refused"
! ok kept tab 1 || fail "keys=1 front=tab accepted"
echo 'launch-ready keys: keys=1 takes front=home, not front=tab'
