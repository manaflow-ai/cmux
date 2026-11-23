#!/usr/bin/env bash
# launch-fresh-install.sh's expected-dialogs marker (cmuxterm-hq "expected dialogs" reads it): with row q or m, one
# <owner>-<pid>.json written atomically (no temp file left) with the contract's fields, there while the rows run,
# gone on exit, a failed run and a TERM included; with rows n,p only, none. And launch-fresh-install-prompts.py presses
# only a new "downloaded from the Internet" prompt, and nothing on a SecurityAgent panel.
#
# No Mac: main runs from a copy of the script in a temp tree, with every Mac tool and the per-row launch replaced by
# stand-ins (no DMG, no CuaDriver, no window). So this proves the marker's life and contents and the prompt helper's
# choices, NOT that the alarm reads the marker or that CuaDriver's press lands on a real prompt.
# Run: bash scripts/measure/tests/launch-fresh-install-marker.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts/measure" "$root/scripts/ci/lib"
cp "$here/launch-fresh-install.sh" "$here/launch-premain.sh" "$here/launch-fresh-install-prompts.py" "$root/scripts/measure/"
echo 'cmux_signing_runtime_guard() { return 0; }' >"$root/scripts/ci/lib/signing-runtime-guard.sh"
fail() { echo "launch-fresh-install marker: $*" >&2; exit 1; }

# run_main DIALOGS ROWS [FAIL_AT]: main with stand-ins; each row's launch records what the marker dir held then.
run_main() {
  local dialogs="$1" rows="$2" fail_at="${3:-}"
  env -u RUNNER_TEMP LF_EXPECTED_DIALOGS_DIR="$dialogs" LF_FAIL_AT="$fail_at" LF_HOLD="${LF_HOLD:-}" LF_SEEN="$root/seen" bash -c '
    source "$1"  # as a library: $0 is not the script, so its main does not run here
    sysctl() { echo 0; }; sw_vers() { echo 26.0; }; launchctl() { echo Aqua; }; sudo() { return 1; }
    xcrun() { :; }
    curl() { local o=""; while (($#)); do [[ "$1" == -o ]] && { o="$2"; shift; }; shift; done; [[ -n "$o" ]] && : >"$o"; }
    gate() { :; }; console() { "$@"; }; wait_load() { :; }
    first() {
      { echo "row $1"; ls -A "$LF_EXPECTED_DIALOGS_DIR" 2>/dev/null; } >>"$LF_SEEN"
      [[ -n "$LF_EXPECTED_DIALOGS_DIR" && -d "$LF_EXPECTED_DIALOGS_DIR" ]] && cat "$LF_EXPECTED_DIALOGS_DIR"/*.json >>"$LF_SEEN.json" 2>/dev/null
      [[ "$1" == "$LF_FAIL_AT" ]] && exit 7
      # A row still running (an interruptible wait, as a TERM finds a job mid-launch).
      [[ -n "$LF_HOLD" ]] && { sleep 30 & echo $! >"$LF_SEEN.sleep"; wait $!; }
      echo "{\"row\": \"$1\", \"rep\": $2, \"mode\": \"first\"}" >>"$OUT/runs.jsonl"
    }
    echo $$ >"$LF_SEEN.pid"
    main dmg=https://example.invalid/x.dmg reps=1 rows='"$rows"'
  ' run-main "$root/scripts/measure/launch-fresh-install.sh"
}

# 1. Rows with q and m: the marker is there for every row, with the contract's fields; gone after.
dialogs="$root/fleet/expected-dialogs"
rm -f "$root/seen" "$root/seen.json"
run_main "$dialogs" n,q,m >"$root/out.txt" 2>&1 || { cat "$root/out.txt"; fail "a clean run failed"; }
pid="$(cat "$root/seen.pid")"
[[ "$(grep -c "^launch-fresh-install-$pid.json\$" "$root/seen")" == 3 ]] || fail "marker not there for each row: $(cat "$root/seen")"
grep -q '^\.' "$root/seen" && fail "a temp file was left beside the marker: $(cat "$root/seen")"
mode="$(python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o7777))' "$dialogs")"
[[ "$mode" == 0o1777 ]] || fail "the dir is not mode 1777: $mode"
python3 -I - "$root/seen.json" "$pid" <<'PY' || fail "marker contents"
import datetime, json, sys
for line in open(sys.argv[1]):
    m = json.loads(line)
    assert set(m) == {"schema", "kinds", "owner", "pid", "expires"}, m
    assert m["schema"] == "expected-dialogs/v1" and m["kinds"] == ["gatekeeper"] and m["owner"] == "launch-fresh-install", m
    assert m["pid"] == int(sys.argv[2]), m
    assert m["expires"].endswith("Z"), m
    left = datetime.datetime.strptime(m["expires"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc) \
        - datetime.datetime.now(datetime.timezone.utc)
    assert datetime.timedelta(minutes=80) < left <= datetime.timedelta(hours=2), left
PY
[[ -z "$(ls -A "$dialogs")" ]] || fail "marker left after a clean run: $(ls -A "$dialogs")"

# 2. A run that fails in a q row: gone, and the failure's exit code kept.
rc=0; run_main "$dialogs" q,m q >"$root/out.txt" 2>&1 || rc=$?
[[ "$rc" == 7 ]] || fail "a failing run exited $rc, want 7"
[[ -z "$(ls -A "$dialogs")" ]] || fail "marker left after a failed run: $(ls -A "$dialogs")"

# 3. A run killed with TERM while a row runs: gone.
rm -f "$root/seen"
rm -f "$root/seen.sleep"
( LF_HOLD=1 run_main "$dialogs" m,q >"$root/out.txt" 2>&1 ) &
for _ in $(seq 100); do [[ -s "$root/seen.sleep" ]] && break; sleep 0.1; done
[[ -n "$(ls -A "$dialogs")" ]] || fail "no marker while the run is live"
kill -TERM "$(cat "$root/seen.pid")"
rc=0; wait $! || rc=$?
kill "$(cat "$root/seen.sleep")" 2>/dev/null || true
[[ "$rc" == 143 ]] || fail "a TERM run exited $rc, want 143"
[[ -z "$(ls -A "$dialogs")" ]] || fail "marker left after TERM (exit $rc): $(ls -A "$dialogs")"

# 4. Rows n,p only: no marker at all, and no dir made for one.
rm -rf "$root/fleet" "$root/seen"
run_main "$dialogs" n,p >"$root/out.txt" 2>&1 || { cat "$root/out.txt"; fail "an n,p run failed"; }
[[ ! -e "$dialogs" ]] || fail "an n,p run wrote a marker: $(ls -A "$dialogs")"

# 5. The prompt helper: a fake CuaDriver with a baseline prompt, a new download prompt, a new other window and a
# SecurityAgent panel. Only the new download prompt is pressed, with the button asked for.
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/pgrep" <<'SH'
#!/bin/sh
case "$2" in CoreServicesUIAgent) echo 100 ;; SecurityAgent) echo 300 ;; *) exit 1 ;; esac
SH
cat >"$bin/cua" <<'SH'
#!/bin/sh
echo "$2 $3" >>"$CUA_LOG"
case "$2" in
  list_windows) case "$3" in
    *100*) if [ -e "$CUA_LOG.clicked" ]; then  # the pressed prompt is gone
        echo '{"structuredContent":{"windows":[{"window_id":1,"is_on_screen":true},{"window_id":3,"is_on_screen":true}]}}'
      else echo '{"structuredContent":{"windows":[{"window_id":1,"is_on_screen":true},{"window_id":2,"is_on_screen":true},{"window_id":3,"is_on_screen":true}]}}'; fi ;;
    *300*) echo '{"structuredContent":{"windows":[{"window_id":9,"is_on_screen":true,"title":"Keychain Not Found"}]}}' ;;
  esac ;;
  get_window_state) case "$3" in
    *'"window_id": 3'*) echo '{"structuredContent":{"elements":[{"role":"AXStaticText","value":"Something else"},{"role":"AXButton","title":"Cancel","element_token":"t3"}]}}' ;;
    *) echo '{"structuredContent":{"elements":[{"role":"AXStaticText","value":"\"(null)\" is an app downloaded from the Internet. Are you sure you want to open it?"},{"role":"AXButton","title":"Open","element_token":"o"},{"role":"AXButton","title":"Cancel","element_token":"c"}]}}' ;;
  esac ;;
  click) : >"$CUA_LOG.clicked"; echo '{}' ;;
esac
SH
chmod +x "$bin/pgrep" "$bin/cua"
export CUA_LOG="$root/cua.log"
: >"$CUA_LOG"
out="$(PATH="$bin:$PATH" python3 -I "$root/scripts/measure/launch-fresh-install-prompts.py" "$bin/cua" press Cancel "1" "after q-1")"
clicks="$(grep '^click ' "$CUA_LOG" || true)"
[[ "$(wc -l <<<"$clicks")" == 1 && "$clicks" == *'"window_id": 2'*'"element_token": "c"'* ]] || fail "wrong presses: $clicks"
grep -q '"pid": 300' "$CUA_LOG" && grep -E '^(get_window_state|click) .*"pid": 300' "$CUA_LOG" && fail "touched SecurityAgent: $(cat "$CUA_LOG")"
grep -q '"action": "left: a keychain.*"owner": "SecurityAgent"' <<<"$out" || fail "the keychain panel is not named: $out"
grep -q '"action": "pressed Cancel, prompt gone".*"window_id": 2' <<<"$out" || fail "no pressed row: $out"
grep -q '"action": "not a download prompt: left".*"window_id": 3' <<<"$out" || fail "window 3 not left: $out"
echo "launch-fresh-install marker: ok"
