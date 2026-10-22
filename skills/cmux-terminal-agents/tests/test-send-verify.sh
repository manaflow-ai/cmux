#!/bin/bash
# Fake-TUI regression tests: every action is followed by a screen check.
# The fake TUI drops a CR that arrives before its paste has rendered, loses
# input sent before it is ready, and can ignore Enter altogether.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
A="$HERE/../scripts/cmux-terminal-agents"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cta-test.XXXXXX")"
export FAKE_CMUX_DIR="$WORK/cmux" HOME="$WORK/home" CMUX_TERMINAL_AGENTS_DIR="$WORK/state"
export CMUX_TERMINAL_AGENTS_CMUX="$WORK/bin/cmux"
mkdir -p "$FAKE_CMUX_DIR" "$HOME" "$WORK/bin" "$WORK/cwd"
printf '#!/bin/bash\nexec python3 %q "$@"\n' "$HERE/fake_cmux.py" >"$WORK/bin/cmux"
chmod +x "$WORK/bin/cmux"

fails=0
pass() { echo "PASS $1"; }
failt() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
cleanup() {
  for p in "$FAKE_CMUX_DIR"/*.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

term_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["terminal_id"])' "$CMUX_TERMINAL_AGENTS_DIR/agents/$1.json"; }
submitted() { cat "$FAKE_CMUX_DIR/$(term_of "$1").submitted" 2>/dev/null; }
field() { python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}")
for k in sys.argv[1].split("."): d=d.get(k) if isinstance(d,dict) else None
print(json.dumps(d, ensure_ascii=False))' "$1"; }
start() { # NAME TUI_ARGS
  FAKE_TUI_ARGS="$2" "$A" start "$1" --no-group --cwd "$WORK/cwd" >"$WORK/$1.start" 2>&1
}

# 1. CR swallowed when it arrives with/right after the paste (one-write send).
start swallow "--swallow-ms 400"
sleep 0.3
out=$("$A" send swallow "Reply with exactly READY." 2>/dev/null); code=$?
sleep 1.5
if submitted swallow | grep -q 'Reply with exactly READY.'; then pass "swallowed CR: prompt submitted"
else failt "swallowed CR: prompt submitted" "agent never got it; send said: $(echo "$out" | head -c 300)"; fi
[ "$code" = 0 ] && [ "$(echo "$out" | field submitted)" = true ] && pass "swallowed CR: send reports submitted:true" \
  || failt "swallowed CR: send reports submitted:true" "exit $code"

# 2. Enter never takes: send must fail loudly with the screen.
start stuck "--ignore-enter"
sleep 0.3
out=$("$A" send stuck --submit-timeout 1 "this never submits" 2>/dev/null); code=$?
if [ "$code" != 0 ] && [ "$(echo "$out" | field submitted)" = false ] && echo "$out" | field screen | grep -q 'this never submits'; then
  pass "ignored Enter: non-zero exit, submitted:false, screen"
else failt "ignored Enter: non-zero exit, submitted:false, screen" "exit $code out=$(echo "$out" | head -c 300)"; fi
presses=$(grep -c '"ev": "cr"' "$FAKE_CMUX_DIR/$(term_of stuck).events" 2>/dev/null)
[ "$presses" = 2 ] && pass "ignored Enter: pressed Enter exactly twice" || failt "ignored Enter: pressed Enter exactly twice" "saw $presses"

# 3. --no-submit leaves the text in the composer and submits nothing.
start comp ""
sleep 0.3
out=$("$A" send comp --no-submit "draft text" 2>/dev/null); code=$?
sleep 0.5
if [ "$code" = 0 ] && [ -z "$(submitted comp)" ] && echo "$out" | field screen | grep -q '❯ draft text'; then pass "--no-submit: rendered, not submitted"
else failt "--no-submit: rendered, not submitted" "exit $code out=$(echo "$out" | head -c 200)"; fi

# 4. Input sent before the TUI is ready is lost: send waits for the composer.
start cold "--ready-ms 1500"
out=$("$A" send cold "cold start prompt" 2>/dev/null); code=$?
sleep 1
if submitted cold | grep -q 'cold start prompt' && [ "$code" = 0 ]; then pass "cold start: prompt submitted"
else failt "cold start: prompt submitted" "exit $code out=$(echo "$out" | head -c 300)"; fi

# 5. choose and steer verify the screen after their keys.
start menu "--swallow-ms 200"
sleep 0.3
"$A" send menu "menu" >/dev/null 2>&1
sleep 0.5
out=$("$A" choose menu 1 2>/dev/null); code=$?
[ "$code" = 0 ] && [ "$(echo "$out" | field verified)" = '"prompt_gone"' ] && pass "choose: verified prompt_gone" \
  || failt "choose: verified prompt_gone" "exit $code out=$(echo "$out" | head -c 300)"
out=$("$A" choose menu 2 --timeout 1 2>/dev/null); code=$?
[ "$code" != 0 ] && pass "choose with no menu on screen fails" || failt "choose with no menu on screen fails" "exit $code"
"$A" send menu "menu" >/dev/null 2>&1
sleep 0.5
out=$("$A" steer menu "do the safe thing instead" 2>/dev/null); code=$?
sleep 0.5
if [ "$code" = 0 ] && [ "$(echo "$out" | field esc.verified)" = '"prompt_gone"' ] && [ "$(echo "$out" | field send.submitted)" = true ] \
  && submitted menu | grep -q 'do the safe thing instead'; then pass "steer: Esc verified, text submitted"
else failt "steer: Esc verified, text submitted" "exit $code out=$(echo "$out" | head -c 400)"; fi

# 6. continue is a verified send; start with a prompt verifies it was taken.
out=$("$A" continue swallow 2>/dev/null); code=$?
[ "$code" = 0 ] && [ "$(echo "$out" | field submitted)" = true ] && pass "continue: submitted:true" || failt "continue: submitted:true" "exit $code"
FAKE_TUI_ARGS="" "$A" start first --no-group --cwd "$WORK/cwd" -- "first prompt here" >"$WORK/first.out" 2>/dev/null; code=$?
v=$(field start.verified <"$WORK/first.out")
[ "$code" = 0 ] && [ "$v" != null ] && pass "start: verified $v" || failt "start: verified state" "exit $code $(head -c 300 "$WORK/first.out")"

# 7. key presses return the screen and what changed.
out=$("$A" key comp backspace 2>/dev/null); code=$?
[ "$code" = 0 ] && [ "$(echo "$out" | field verified)" = '"screen_changed"' ] && pass "key: screen_changed" || failt "key: screen_changed" "exit $code out=$(echo "$out" | head -c 300)"

# 8. wait: a hook that says idle before working (Codex) must not end the turn.
start hooked "--hook --busy-ms 2500"
sleep 0.3
out=$("$A" send hooked --wait --idle-seconds 0 --timeout 20 "Reply with exactly READY." 2>/dev/null); code=$?
since=$(echo "$out" | field wait.since_send_seconds)
if [ "$code" = 0 ] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 2.4 else 1)' "$since" 2>/dev/null; then
  pass "wait: early hook idle ignored (ended after ${since}s via $(echo "$out" | field wait.via))"
else failt "wait: early hook idle ignored" "ended after ${since}s via $(echo "$out" | field wait.via)"; fi

# 9. A menu that shows after the composer (Codex "Hooks need review"): send stops, types nothing.
start late "--late-menu-ms 600"
out=$("$A" send late "must not reach the menu" 2>/dev/null); code=$?
typed=$(grep -c typed_into_menu "$FAKE_CMUX_DIR/$(term_of late).events" 2>/dev/null)
if [ "$code" != 0 ] && [ "$(echo "$out" | field stage)" = '"blocked_on_prompt"' ] && [ "${typed:-0}" = 0 ]; then
  pass "late menu: blocked_on_prompt, nothing typed into it"
else failt "late menu: blocked_on_prompt, nothing typed into it" "exit $code stage $(echo "$out" | field stage) typed ${typed:-0}"; fi

# 10. choose on a menu that ignores digits (Codex): arrows + Enter, checked.
out=$("$A" choose late 2 --timeout 2 2>/dev/null); code=$?
if [ "$code" = 0 ] && [ "$(echo "$out" | field verified)" = '"prompt_gone"' ] && grep -q '"option": "2"' "$FAKE_CMUX_DIR/$(term_of late).events"; then
  pass "choose: digit ignored, arrows picked option 2"
else failt "choose: digit ignored, arrows picked option 2" "exit $code out=$(echo "$out" | head -c 300)"; fi

# 11. wait with no turn sent yet reports no since-send time (not seconds since 1970).
start fresh ""
out=$("$A" wait fresh --idle-seconds 1 --timeout 5 2>/dev/null); code=$?
s=$(echo "$out" | field since_send_seconds)
[ "$code" = 0 ] && [ "$s" = null ] && pass "wait without a turn: since_send_seconds null" || failt "wait without a turn: since_send_seconds null" "exit $code since=$s"

echo
if [ "$fails" = 0 ]; then echo "cmux-terminal-agents send-verify tests passed"; else echo "$fails test(s) failed"; exit 1; fi
