#!/usr/bin/env bash
# The stand-in sudo's body is single-quoted on purpose: it expands when the stand-in runs.
# shellcheck disable=SC2016,SC2034  # SC2034: the sourced script reads EXE, FW, REP and ARM
# launch-premain.sh's settle=1 and its root check, on Linux with stand-ins: settle= takes 0 or 1 (anything else exits 2
# before the run starts); with settle=1 each measured B is asked to run to its settle (open: RUN_S and "settle"; exec
# and sampled: settle=S) and the wait drops to 6 s once the build shows no window_usable; LP-TABLE gains the settle
# columns (median, min, max per arm) and settle_by counts from runs.jsonl rows, and settle=0 leaves it as it was; the
# LP root line comes from `sudo -n -l CMD` per command (a purge-only sudoers says purge, where `sudo -n true` said no),
# and the fs_usage record runs only when sudo allows /usr/bin/fs_usage.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../launch-premain.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/launch-premain-settle-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "launch-premain settle: $*" >&2; exit 1; }

# settle= parse: bad values exit 2 with a message, from the script itself (parse_args runs before anything else).
for bad in settle=2 settle=yes settle= settle=01; do
  set +e; err="$(bash "$script" "$bad" 2>&1 >/dev/null)"; rc=$?; set -e
  [[ "$rc" == 2 ]] || fail "$bad: want exit 2, got $rc ($err)"
  [[ "$err" == *"settle= takes 0 or 1"* ]] || fail "$bad: want the settle= message, got: $err"
done

# shellcheck source=scripts/measure/launch-premain.sh
source "$script"
parse_args; [[ "$SETTLE" == 0 ]] || fail "default settle is $SETTLE, want 0"
parse_args reps=2 settle=1 arms=h,x; [[ "$SETTLE" == 1 && "$SETTLE_S" == 15 && "$REPS" == 2 && "$ARMS" == h,x ]] \
  || fail "settle=1 parse: SETTLE=$SETTLE SETTLE_S=$SETTLE_S REPS=$REPS ARMS=$ARMS"
parse_args settle=0; [[ "$SETTLE" == 0 ]] || fail "settle=0 parse: $SETTLE"
(parse_args settle=on 2>/dev/null) && fail "settle=on was taken"

# measured with settle=1: B per mode gets the settle arguments; the wait drops to 6 s after a B with no window_usable.
OUT="$tmp" EXE="$tmp/exe" FW="" REP=1 ARM=h
: >"$OUT/runs.jsonl"
stat() { echo 1; }
checker_cpu() { echo "syspolicyd=0 xprotect=0 amfid=0 trustd=0"; }
record() { :; }
launch() { echo "$*" >>"$tmp/launches"; echo "$LP_ROW" >>"$OUT/runs.jsonl"; }
SETTLE=1 SETTLE_S=15
LP_ROW='{"arm": "h", "role": "B", "settle_by": "window+6s"}' measured open >/dev/null
LP_ROW='{"arm": "x", "role": "B", "settle_by": "window+6s"}' measured exec >/dev/null
[[ "$(sed -n 1p "$tmp/launches")" == "open B 15 settle" ]] || fail "open B: $(sed -n 1p "$tmp/launches")"
[[ "$(sed -n 2p "$tmp/launches")" == "exec B settle=6" ]] || fail "exec B after a B with no window_usable: $(sed -n 2p "$tmp/launches")"
: >"$OUT/runs.jsonl"; : >"$tmp/launches"; SETTLE_S=15
LP_ROW='{"arm": "h", "role": "B", "settle_by": "window_usable"}' measured open >/dev/null
LP_ROW='{"arm": "h", "role": "B", "settle_by": "window+6s"}' measured open >/dev/null
[[ "$SETTLE_S" == 15 ]] || fail "the wait dropped though a B marked window_usable"
SETTLE=0; : >"$tmp/launches"
LP_ROW='{}' measured open >/dev/null; LP_ROW='{}' measured exec >/dev/null
[[ "$(cat "$tmp/launches")" == $'open B 0 term\nexec B' ]] || fail "settle=0 changed B: $(cat "$tmp/launches")"

# LP-TABLE from stand-in rows.
cat >"$tmp/rows.jsonl" <<'ROWS'
{"arm": "h", "role": "B", "main_start": 40, "first_window_frame_committed": 500, "launch_shell.committed": 900, "window_on_screen": 450, "window_usable": 2000, "settle": 2000, "settle_by": "window_usable"}
{"arm": "h", "role": "B", "main_start": 60, "first_window_frame_committed": 700, "launch_shell.committed": 1100, "window_on_screen": 650, "window_usable": 2400, "settle": 2400, "settle_by": "window_usable"}
{"arm": "h", "role": "B", "main_start": 50, "first_window_frame_committed": 600, "launch_shell.committed": null, "window_on_screen": 550, "window_usable": null, "settle": 6550, "settle_by": "window+6s"}
{"arm": "h", "role": "checkers", "syspolicyd_ms": 10}
{"arm": "x", "role": "B", "main_start": 900, "first_window_frame_committed": 1500, "launch_shell.committed": null, "window_on_screen": 1400, "settle": 7400, "settle_by": "window+6s", "stopped_at_main_ms": 3}
ROWS
table="$(lp_table "$tmp/rows.jsonl" 1)"
cat >"$tmp/check.py" <<'PY'
import json, sys
rows = {t["arm"]: t for t in (json.loads(l.split(" ", 1)[1]) for l in sys.stdin if l.startswith("LP-TABLE "))}
h, x = rows["h"], rows["x"]
assert h["n"] == 3 and x["n"] == 1, rows
assert h["first_window_frame_committed"] == {"median": 600, "min": 500, "max": 700}, h
assert h["launch_shell.committed"] == {"median": 1000.0, "min": 900, "max": 1100}, h
assert h["settle"] == {"median": 2400, "min": 2000, "max": 6550}, h
assert h["window_on_screen"] == {"median": 550, "min": 450, "max": 650}, h
assert h["settle_by"] == {"window_usable": 2, "window+6s": 1}, h
assert x["launch_shell.committed"] is None and x["settle"] == {"median": 7400, "min": 7400, "max": 7400}, x
assert h["main_start"] == {"median": 50, "min": 40, "max": 60}, h
PY
python3 -I "$tmp/check.py" <<<"$table" || fail "settle LP-TABLE: $table"
plain="$(lp_table "$tmp/rows.jsonl" 0)"
grep -qE 'settle|first_window_frame_committed|launch_shell' <<<"$plain" && fail "settle=0 LP-TABLE has settle columns: $plain"
grep -q '"main_start": {"median": 50' <<<"$plain" || fail "settle=0 LP-TABLE: $plain"

# Root check with a stand-in sudo on PATH: it allows `-n -l CMD` for the commands in FAKE_SUDO_ALLOW and refuses
# everything else, `sudo -n true` included (as a purge-only sudoers does). Calls go to $tmp/sudo-calls.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/sudo-calls"\n%s\n' "$tmp" '
[[ "$1" == -n ]] || exit 1
if [[ "$2" == -l ]]; then for c in $FAKE_SUDO_ALLOW; do [[ "$3" == "$c" ]] && { echo "$c"; exit 0; }; done; echo "sudo: a password is required" >&2; exit 1; fi
for c in $FAKE_SUDO_ALLOW; do [[ "$2" == "$c" ]] && exit 0; done
echo "sudo: a password is required" >&2; exit 1' >"$tmp/bin/sudo"
chmod +x "$tmp/bin/sudo"
PATH="$tmp/bin:$PATH"
want() { local got; got="$(FAKE_SUDO_ALLOW="$1" root_check)"; [[ "$got" == "$2" ]] || fail "root with '$1': want '$2', got '$got'"; }
want "/usr/sbin/purge" "LP root yes (allowed: purge; refused: fs_usage, sample)"
want "" "LP root no (arms d and f need it: their rows say so)"
want "/usr/sbin/purge /usr/bin/fs_usage /usr/bin/sample" "LP root yes (allowed: purge, fs_usage, sample)"
want "/usr/bin/fs_usage" "LP root yes (allowed: fs_usage; refused: purge, sample)"
grep -qx -- '-n true' "$tmp/sudo-calls" && fail "root check still asks sudo -n true"

# fsrec: fs_usage only when sudo allows /usr/bin/fs_usage, whatever purge's answer.
sleep() { :; }
: >"$tmp/sudo-calls"
FAKE_SUDO_ALLOW="/usr/sbin/purge" fsrec a
grep -q '/usr/bin/fs_usage -w' "$tmp/sudo-calls" && fail "fsrec ran fs_usage on a purge-only host"
FAKE_SUDO_ALLOW="/usr/sbin/purge /usr/bin/fs_usage" fsrec a
wait
grep -q -- '-n /usr/bin/fs_usage -w -t 8' "$tmp/sudo-calls" || fail "fsrec did not run fs_usage where sudo allows it: $(cat "$tmp/sudo-calls")"
echo "launch-premain settle: ok"
