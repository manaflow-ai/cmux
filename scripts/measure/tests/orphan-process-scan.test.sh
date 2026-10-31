#!/usr/bin/env bash
# scripts/measure/orphan-process-scan.sh: feeds a canned `ps` table through a stub ps (no real process is
# read or signalled) and checks which rows count as orphans and how each is described. Safe anywhere.
# Run: bash scripts/measure/tests/orphan-process-scan.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/measure/orphan-process-scan.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck disable=SC1091 source=../orphan-process-scan.sh
source "$SCRIPT"
[[ "$(etime_seconds 59:59)" == 3599 ]] || fail "mm:ss"
[[ "$(etime_seconds 01:00:01)" == 3601 ]] || fail "hh:mm:ss"
[[ "$(etime_seconds 3-04:05:06)" == $((3 * 86400 + 4 * 3600 + 5 * 60 + 6)) ]] || fail "dd-hh:mm:ss"
[[ "$(etime_seconds 08:09)" == 489 ]] || fail "leading zeros are decimal"
[[ "$(arg_value --socket "x --socket /a/b.sock --y")" == /a/b.sock ]] || fail "--socket PATH"
[[ "$(arg_value --socket "x --socket=/a/c.sock")" == /a/c.sock ]] || fail "--socket=PATH"
[[ -z "$(arg_value --socket "x --socketx /a")" ]] || fail "a longer flag is not --socket"
[[ "$(process_kind /x/cmux-tui "cmux-tui __terminal-host --bootstrap-stdio")" == terminal_host ]] || fail "host kind"
[[ "$(process_kind /x/acpmux "acpmux serve")" == acpmux ]] || fail "acpmux kind"
[[ "$(process_kind "(acpmux)" "(acpmux)")" == acpmux ]] || fail "another user's acpmux"
[[ "$(process_kind /x/cmux-tui "cmux-tui --headless --socket /s")" == daemon ]] || fail "daemon kind"
[[ "$(owner_alive "cmux-tui __terminal-host --owner app@$$")" == yes ]] || fail "live owner"
[[ "$(owner_alive "cmux-tui __terminal-host --owner app@999999999")" == no ]] || fail "dead owner"
[[ "$(owner_alive "cmux-tui __terminal-host --bootstrap-stdio")" == - ]] || fail "no owner"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$TMP/live.sock"
[[ "$(socket_state "$TMP/live.sock")" == present ]] || fail "socket present"
[[ "$(socket_state "$TMP/gone/x.sock")" == missing ]] || fail "socket missing"
[[ "$(socket_state "")" == - ]] || fail "no socket"

# The whole report through a stub ps. Columns: pid ppid etime pcpu time user args.
mkdir -p "$TMP/bin"
cat > "$TMP/table" <<TABLE
  101     1 10-01:00:00   0.0 0:01.00 ec2-user /opt/b/cmux-tui __terminal-host --bootstrap-stdio
  102     1  2-00:00:00  87.5 99:00.00 ec2-user /opt/b/cmux-tui --headless --socket $TMP/gone/run/owner.sock
  103     1    01:00:01   0.1 0:00.10 ec2-user /opt/b/cmux-tui __terminal-host --owner app@999999999 --socket $TMP/live.sock
  104     1    59:00   0.0 0:00.01 ec2-user /opt/b/cmux-tui --headless
  105   400  5-00:00:00   0.0 0:00.01 ec2-user /opt/b/cmux-tui --headless
  106     1  1-00:00:00   0.0 0:00.01 ec2-user /opt/a/acpmux serve
  107     1  1-00:00:00   0.0 0:00.01 ec2-user /bin/bash -c sleep 1 # mentions cmux-tui
  108     1  1-00:00:00   0.0 0:00.01 other (cmux-tui)
  109   400  1-00:00:00   0.0 0:00.01 ec2-user $TMP/fixed/cmux-tui --headless
TABLE
mkdir -p "$TMP/fixed"
printf 'elf\0owner-lost-paths\0' > "$TMP/fixed/cmux-tui"
touch -t 200001010000 "$TMP/fixed/cmux-tui"
cat > "$TMP/bin/ps" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "-A -o"*) cat "$TMP/table" ;;
  *"-o lstart="*) echo "Fri Oct 31 10:00:00 2026" ;;
  *"-o comm="*) case "\$2" in 106) echo /opt/a/acpmux ;; 107) echo /bin/bash ;; 108) echo cmux-tui ;; 109) echo "$TMP/fixed/cmux-tui" ;; *) echo /opt/b/cmux-tui ;; esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/ps"
out=$(PATH="$TMP/bin:$PATH" ORPHAN_SCAN_PROC="$TMP/no-proc" bash "$SCRIPT")
echo "$out"
grep -q '^ORPHAN-SCAN-HOST host=' <<<"$out" || fail "host line"
for pid in 101 102 103 106 108; do grep -q "^ORPHAN pid=$pid " <<<"$out" || fail "orphan $pid not listed"; done
for pid in 104 105 107; do ! grep -q "^ORPHAN pid=$pid " <<<"$out" || fail "pid $pid is not an orphan"; done
grep -q "^ORPHAN pid=102 .*socket_state=missing kind=daemon" <<<"$out" || fail "102 socket missing"
grep -q "^ORPHAN pid=103 .*owner_alive=no socket=$TMP/live.sock socket_state=present kind=terminal_host" <<<"$out" || fail "103"
grep -q '^ORPHAN pid=101 .*lstart="Fri Oct 31 10:00:00 2026 UTC" .*owner_alive=- socket=- socket_state=- kind=terminal_host' <<<"$out" || fail "101"
grep -q '^ORPHAN-SCAN-SUMMARY count=5 terminal_hosts=2 daemons=2 acpmux=1 spinning=1$' <<<"$out" || fail "summary"
grep -q '^ORPHAN-SCAN-BUILDS path="/opt/b/cmux-tui" processes=5 orphans=3 fix29349=- ' <<<"$out" || fail "builds"
grep -q '^ORPHAN-SCAN-BUILDS path="cmux-tui" processes=1 orphans=1 fix29349=- replaced_after_start=0$' <<<"$out" || fail "a bare name is not a file"
grep -q "^ORPHAN-SCAN-BUILDS path=\"$TMP/fixed/cmux-tui\" processes=1 orphans=0 fix29349=yes replaced_after_start=0\$" <<<"$out" || fail "a build with the fix"
echo "orphan-process-scan.test.sh: ok"
