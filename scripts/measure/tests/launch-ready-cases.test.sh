#!/usr/bin/env bash
# launch-ready.sh's restore cases: which case arguments combine (case_args_ok), daemon=cold ending only the side's
# copy's processes, snapshot=unknown removing only the home's workspace registry files, and the summary reading a
# runs.jsonl end to end (launch-ready-summary.py).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# shellcheck source=../launch-ready.sh
source "$here/launch-ready.sh"

ok() { LR_STATE="$1" LR_CASE="$2" LR_DAEMON="$3" LR_SNAPSHOT="$4" LR_FRONT="$5" case_args_ok "$6" "$7" 2>/dev/null; }
sha=0123456789abcdef0123456789abcdef01234567
ok kept "" warm own home "" small || { echo "state=kept front=home refused" >&2; exit 1; }
ok kept update warm own home "$sha" small || { echo "state=kept case=update front=home refused" >&2; exit 1; }
ok kept "" cold own home "" small || { echo "state=kept daemon=cold front=home refused" >&2; exit 1; }
ok kept "" cold unknown "" "" small || { echo "snapshot=unknown refused" >&2; exit 1; }
! ok kept update warm own "" "" small || { echo "case=update without base= accepted" >&2; exit 1; }
! ok bare "" cold own "" "" small || { echo "state=fresh daemon=cold accepted" >&2; exit 1; }
! ok bare "" warm own home "" small || { echo "state=fresh front=home accepted" >&2; exit 1; }
! ok kept "" warm own tab "" stress3 || { echo "front=tab session=stress3 accepted" >&2; exit 1; }
echo 'launch-ready cases: the case arguments combine as agreed'

# cold_daemon: kills only the pids running from OUT/SIDE/, and with snapshot=unknown removes only the registry files.
out="$root/out"
mkdir -p "$out/head" "$out/home-head/h/Library/Application Support/cmux/state/s1"
state="$out/home-head/h/Library/Application Support/cmux/state/s1"
touch "$state/workspace-registry.sqlite3" "$state/workspace-registry.sqlite3-wal" "$state/machine-id"
ps() {
  case "$*" in
    *pid=,command=*) printf '%s\n' "101 $out/head/cmux NEXT.app/Contents/Resources/bin/cmux-tui daemon" \
      "102 $out/base/cmux NEXT.app/Contents/Resources/bin/cmux-tui daemon" "103 /usr/sbin/cfprefsd agent" ;;
    *) return 1 ;; # ps -p: none left
  esac
}
killed=""
kill() { killed="$killed $*"; }
sleep() { :; }
line="$(LR_SNAPSHOT=unknown cold_daemon "$out" head run1)"
[[ "$line" == "LR-COLD head run1 stopped=1 registry_files_removed=2" ]] || { echo "cold_daemon printed '$line'" >&2; exit 1; }
[[ -f "$state/machine-id" && ! -e "$state/workspace-registry.sqlite3" ]] || { echo "cold_daemon removed the wrong files" >&2; exit 1; }
LR_SNAPSHOT=own cold_daemon "$out" head run2 >/dev/null
[[ "$killed" == *101* && "$killed" != *102* && "$killed" != *103* ]] || { echo "cold_daemon killed '$killed'" >&2; exit 1; }
! LR_SNAPSHOT=unknown cold_daemon "$out" head run3 >/dev/null || { echo "snapshot=unknown with no registry passed" >&2; exit 1; }
unset -f ps kill sleep
echo 'launch-ready cases: daemon=cold ends only the copy'"'"'s daemons; snapshot=unknown removes only the registry'

# The summary end to end: an A/B whose head restored tabs where base showed Home.
{
  echo '{"side":"base","label":"prime","marks":{},"front":{"workspace":"w","tab":"t0","home":true}}'
  echo '{"side":"head","label":"prime","marks":{},"front":{"workspace":"w","tab":"t0","home":true}}'
  echo '{"side":"base","label":"run1","window_on_screen":1,"first_reveal":"home","marks":{"home.first_page":2},"front":{"workspace":"w","tab":"t1","home":true}}'
  echo '{"side":"head","label":"run1","window_on_screen":1,"first_reveal":"tabs","marks":{"reveal.tabs":2},"front":{"workspace":"w","tab":"t2","home":false}}'
} >"$root/runs.jsonl"
summary="$(python3 -I "$here/launch-ready-summary.py" "$root/runs.jsonl" --state kept --case "" --daemon warm --snapshot own --front "")"
for want in "LR-CASE kept expect=last" "LR-REOPENED base 1/1 case=kept" "LR-REOPENED head 0/1 case=kept" \
  "LR-SURFACE head first=tabs home_page_drawn=0/1 mix=tabs:1" "LR-SURFACE-DIFF base first=home head first=tabs: not like for like"; do
  grep -qxF "$want" <<<"$summary" || { echo "summary lacks '$want':"; echo "$summary"; exit 1; } >&2
done
grep -q '^LR-FAIL head run1 landed on workspace=w tab=t2, last front was Home$' <<<"$summary" \
  || { echo "summary lacks head's LR-FAIL:"; echo "$summary"; exit 1; } >&2
echo 'launch-ready cases: the summary flags the A/B not like for like'
