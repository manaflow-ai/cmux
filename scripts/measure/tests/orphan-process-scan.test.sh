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
[[ "$(classify /x/cmux-tui "/x/cmux-tui __terminal-host --bootstrap-stdio")" == "counted terminal_host" ]] || fail "host"
[[ "$(classify /x/acpmux "/x/acpmux daemon run")" == "counted acpmux" ]] || fail "acpmux by name"
[[ "$(classify acpmux "/x/acpmux daemon run")" == "counted acpmux" ]] || fail "acpmux by Linux comm"
[[ "$(classify /x/cmux-tui "/x/cmux-tui acp daemon run")" == "counted acpmux" ]] || fail "cmux-tui acp"
[[ "$(classify "/A/cmux NEXT.app/C/bin/cmux-tui" "/A/cmux NEXT.app/C/bin/cmux-tui --headless --socket /s")" == "counted daemon" ]] || fail "path with a space"
[[ "$(classify /x/bin/cmux "/x/bin/cmux acp daemon run")" == "via_cmux acpmux" ]] || fail "multicall acp"
[[ "$(classify /x/bin/cmux "/x/bin/cmux __terminal-host --owner a@1")" == "via_cmux terminal_host" ]] || fail "multicall host"
[[ "$(classify /x/bin/cmux "/x/bin/cmux --headless --session main")" == "via_cmux daemon" ]] || fail "multicall owner"
[[ "$(classify /x/bin/cmux "/x/bin/cmux notify hi")" == skip ]] || fail "a CLI call is not an orphan"
[[ "$(classify cmux "(cmux)")" == "unreadable unknown" ]] || fail "another user's (cmux)"
[[ "$(classify cmux-tui "(cmux-tui)")" == "counted unknown" ]] || fail "another user's (cmux-tui)"
[[ "$(classify /bin/bash "/bin/bash -c x cmux-tui")" == skip ]] || fail "a shell that mentions cmux-tui"
[[ "$(owner_alive "cmux-tui __terminal-host --owner app@$$" 0)" == yes ]] || fail "live owner"
[[ "$(owner_alive "cmux-tui __terminal-host --owner app@$$" 999999999)" == reused ]] || fail "owner started after the host"
[[ "$(owner_alive "cmux-tui __terminal-host --owner app@999999999" 0)" == no ]] || fail "dead owner"
[[ "$(owner_alive "cmux-tui __terminal-host --bootstrap-stdio" 0)" == - ]] || fail "no owner"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$TMP/live.sock"
[[ "$(socket_state "$TMP/live.sock")" == present ]] || fail "socket present"
[[ "$(socket_state "$TMP/gone/x.sock")" == missing ]] || fail "socket missing"
[[ "$(socket_state "")" == - ]] || fail "no socket"

# The whole report through a stub ps. Columns: pid ppid etime pcpu time user args.
mkdir -p "$TMP/bin"
mkdir -p "$TMP/fixed" "$TMP/old"
printf 'elf\0owner-lost-paths\0' > "$TMP/fixed/cmux-tui"
printf 'elf\0' > "$TMP/old/cmux-tui"
touch -t 200001010000 "$TMP/fixed/cmux-tui" "$TMP/old/cmux-tui"
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
  110     1  1-00:00:00   0.0 0:00.01 ec2-user $TMP/old/cmux-tui acp daemon run
  111     1  1-00:00:00   0.0 0:00.01 ec2-user /h/bin/cmux --headless --session main
  112     1  1-00:00:00   0.0 0:00.01 other (cmux)
  113     1  1-00:00:00   0.0 0:00.01 ec2-user /Applications/cmux.app/Contents/MacOS/cmux
TABLE
cat > "$TMP/bin/ps" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "-A -o"*) cat "$TMP/table" ;;
  *"-o lstart="*) echo "Fri Oct 31 10:00:00 2026" ;;
  *"-o etime="*) exit 1 ;;
  *"-o comm="*)
    case "\$2" in
      106) echo /opt/a/acpmux ;; 107) echo /bin/bash ;; 108) echo cmux-tui ;; 109) echo "$TMP/fixed/cmux-tui" ;;
      110) echo "$TMP/old/cmux-tui" ;; 111) echo /h/bin/cmux ;; 112) echo cmux ;; 113) echo /Applications/cmux.app/Contents/MacOS/cmux ;;
      *) echo /opt/b/cmux-tui ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/ps"
out=$(PATH="$TMP/bin:$PATH" ORPHAN_SCAN_PROC="$TMP/no-proc" bash "$SCRIPT")
echo "$out"
grep -q '^ORPHAN-SCAN-HOST host=' <<<"$out" || fail "host line"
for pid in 101 102 103 106 108 110 111 112; do grep -q "^ORPHAN pid=$pid " <<<"$out" || fail "orphan $pid not listed"; done
for pid in 104 105 107 109 113; do ! grep -q "^ORPHAN pid=$pid " <<<"$out" || fail "pid $pid is not an orphan"; done
grep -q "^ORPHAN pid=102 .*socket_state=missing group=counted kind=daemon" <<<"$out" || fail "102 socket missing"
grep -q "^ORPHAN pid=103 .*owner_alive=no socket=$TMP/live.sock socket_state=present group=counted kind=terminal_host" <<<"$out" || fail "103"
grep -q '^ORPHAN pid=101 .*lstart="Fri Oct 31 10:00:00 2026 UTC" .*owner_alive=- socket=- socket_state=- group=counted kind=terminal_host' <<<"$out" || fail "101"
grep -q '^ORPHAN pid=110 .*group=counted kind=acpmux' <<<"$out" || fail "110 cmux-tui acp"
grep -q '^ORPHAN pid=111 .*group=via_cmux kind=daemon' <<<"$out" || fail "111 multicall"
grep -q '^ORPHAN pid=112 .*group=unreadable kind=unknown' <<<"$out" || fail "112 unreadable"
grep -q '^ORPHAN-SCAN-SUMMARY count=6 terminal_hosts=2 daemons=1 acpmux=2 unknown=1 spinning=1 via_cmux=1 unreadable=1$' <<<"$out" || fail "summary"
grep -q '^ORPHAN-SCAN-BUILDS path="/opt/b/cmux-tui" processes=5 orphans=3 fix29349=- ' <<<"$out" || fail "builds"
grep -q "^ORPHAN-SCAN-BUILDS path=\"$TMP/fixed/cmux-tui\" processes=1 orphans=0 fix29349=yes replaced_after_start=0\$" <<<"$out" || fail "a build with the fix"
grep -q "^ORPHAN-SCAN-BUILDS path=\"$TMP/old/cmux-tui\" processes=1 orphans=1 fix29349=no replaced_after_start=0\$" <<<"$out" || fail "a build without the fix"
grep -q '^ORPHAN-SCAN-BUILDS path="cmux-tui" processes=1 orphans=1 fix29349=- replaced_after_start=0$' <<<"$out" || fail "a bare name is not a file"
grep -q '^ORPHAN-SCAN-BUILDS path="/h/bin/cmux" processes=1 orphans=1 fix29349=- ' <<<"$out" || fail "multicall build"
# Fed on stdin, as `ssh HOST bash -s < orphan-process-scan.sh` runs it on a host the fleet cannot
# reach: BASH_SOURCE is unset there, and the report must still come out the same.
stdin_out=$(PATH="$TMP/bin:$PATH" ORPHAN_SCAN_PROC="$TMP/no-proc" bash -s <"$SCRIPT" 2>&1) || fail "bash -s: $stdin_out"
[[ "$(grep '^ORPHAN-SCAN-SUMMARY' <<<"$stdin_out")" == "$(grep '^ORPHAN-SCAN-SUMMARY' <<<"$out")" ]] \
  || fail "the report on stdin differs: $stdin_out"
echo "orphan-process-scan.test.sh: ok"
