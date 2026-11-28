#!/usr/bin/env bash
# The stand-ins' bodies are single-quoted on purpose: they expand when the stand-in runs.
# shellcheck disable=SC2016
# launch-reboot.sh on Linux with stand-ins for every Mac command (sysctl, ps, sudo, xcrun, curl, hdiutil, ditto, stat,
# sleep, PlistBuddy, /usr/bin/time, the console hop and the probe): bad arguments are refused (exit 2, LB-FAIL); the
# before phase installs the copy, primes it, exits 0 and calls `sudo -n /sbin/shutdown -r now` after it, detached
# (recorded, never run), from / with an empty environment; the after phase refuses with no before step's state, while
# kern.boottime is still the before step's and when the boot is over 600 s old, and prints the reboot's log; its s_since_login comes from loginwindow's age, else kern.boottime; the read arm prints one LB-READ per
# binary; the residency arm prints LB-RESIDENT at +1m, +10m and +60m; a missing copy is an LB-FAIL.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../launch-reboot.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/launch-reboot-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
bin="$tmp/bin" calls="$tmp/calls"
mkdir -p "$bin"
: >"$calls"

stub() { printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$calls" "$2" >"$bin/$1"; chmod +x "$bin/$1"; }
stub sysctl 'case "$*" in *kern.boottime*) echo "{ sec = $FAKE_BOOT, usec = 0 } Wed Nov 18 10:00:00 2026" ;; *brand*) echo "Fake M1" ;; *loadavg*) echo "{ 1.00 1.00 1.00 }" ;; esac'
stub sw_vers 'echo 26.1'
stub launchctl 'echo Aqua'
stub sleep ':'
# ps: loginwindow's age (FAKE_LOGIN_ETIME), the checkers' CPU growing 500 ms per read, no copy processes.
stub ps 'case "$*" in
  *etime=*) [[ -n "${FAKE_LOGIN_ETIME:-}" ]] && echo "${FAKE_LOGIN_ETIME} /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"; echo "   02:00 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" ;;
  *time=,comm=*) n=$(($(cat "$FAKE_PS_N" 2>/dev/null || echo 0) + 1)); echo $n >"$FAKE_PS_N"
    echo "0:0$n.00 /usr/libexec/syspolicyd"; echo "0:00.$n /usr/libexec/XprotectService"; echo "0:00.00 /usr/libexec/amfid" ;;
esac'
stub sudo 'exit 0'
stub stat 'f="${!#}"; /usr/bin/stat -L -c %s "$f"'
stub xcrun 'while (($#)); do [[ "$1" == -o ]] && { cp "$FAKE_PROBE" "$2"; chmod +x "$2"; }; shift; done'
stub curl 'out=""; url=""; while (($#)); do case "$1" in -o) out="$2"; shift ;; -A|-H|--proto|--retry) shift ;; -*) ;; *) url="$1" ;; esac; shift; done
  case "$url" in *appcast*) echo "<enclosure url=\"https://files.invalid/cmux-macos-arm64-123.dmg\"/>" ;; *) echo dmg >"$out" ;; esac'
stub hdiutil 'case "$1" in attach) m="${@: -1}"; mkdir -p "$m"; cp -R "$FAKE_APP" "$m/" ;; esac'
stub ditto 'cp -R "$1" "$2"'
stub plistbuddy 'case "$2" in *CFBundleExecutable) echo cmux ;; *CFBundleVersion) echo 123 ;; *) echo 0.1 ;; esac'
stub time 'shift; "$@"; echo "        0.12 real         0.01 user         0.05 sys" >&2; echo "   1179648  maximum resident set size" >&2'
stub console '"$@"'
cat >"$tmp/probe" <<EOF
#!/usr/bin/env bash
echo "probe \$*" >>"$calls"
case "\$1" in
  open) [[ -n "\${FAKE_NO_USABLE:-}" ]] && u=null || u=900.3
    echo 'LP-RUN {"first_window_frame_committed":310.5,"label":"B","main_start":120.2,"mode":"open","pageins":4321,"request_to_start":45.1,"window_on_screen":420.7,"window_usable":'\$u'}' ;;
  resident) echo "LP-RESIDENT 0.25 10 40" ;;
esac
EOF
# The fixture app: a stub executable, CmuxNextApp and Chromium Embedded Framework, each of its own size.
app="$tmp/fixture/cmux NEXT.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/CmuxNextApp.framework/Versions/A" \
  "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A"
echo plist >"$app/Contents/Info.plist"
head -c 3000 /dev/zero >"$app/Contents/MacOS/cmux"
head -c 5000 /dev/zero >"$app/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp"
head -c 7000 /dev/zero >"$app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"

export PATH="$bin:$PATH" LB_ROOT="$tmp/root" LB_CONSOLE="$bin/console" LB_TIME="$bin/time" LB_PLISTBUDDY="$bin/plistbuddy" \
  FAKE_PROBE="$tmp/probe" FAKE_APP="$app" FAKE_PS_N="$tmp/ps-n" FAKE_BOOT=0 LB_REBOOT_DELAY=0
unset RUNNER_TEMP CMUX_SIGNING_KEYCHAIN_STATE_DIR FAKE_LOGIN_ETIME FAKE_NO_USABLE
[[ "$(command -v sudo)" == "$bin/sudo" ]] || { echo "launch-reboot test: sudo is not the stand-in" >&2; exit 1; }
die() { echo "launch-reboot test: $*" >&2; exit 1; }
# shutdown_called: the detached shutdown recorded, within 5 s of the before step's exit.
shutdown_called() {
  local i
  for ((i = 0; i < 50; i++)); do grep -q '^sudo -n /sbin/shutdown -r now$' "$calls" && return 0; /bin/sleep 0.1; done
  return 1
}

# Bad arguments: exit 2 with an LB-FAIL row.
for args in "" "phase=after reboot=1" "phase=after arm=bogus reboot=1" "phase=before reboot=x" "phase=before reboot=1 arm=read" \
  "phase=before reboot=1 foo=1" "phase=sideways reboot=1"; do
  read -r -a words <<<"$args"
  set +e; out="$(bash "$script" ${words[@]+"${words[@]}"})"; rc=$?; set -e
  [[ $rc == 2 && "$out" == "LB-FAIL bad argument:"* ]] || die "args '$args': want exit 2 and LB-FAIL, got $rc: $out"
done

# The after phase with no before step's state (a root the before step never wrote, as under a per-step HOME).
set +e; out="$(FAKE_BOOT=$(($(date +%s) - 100)) bash "$script" phase=after arm=noread reboot=1)"; rc=$?; set -e
if [[ $rc != 3 ]] || ! grep -q '^LB-FAIL reboot=1 no before step: ' <<<"$out"; then die "no before step: want LB-FAIL and exit 3, got $rc: $out"; fi

# Before: installs the copy (reboot=1), primes it, exits 0, then the detached shutdown.
: >"$calls"
out="$(bash "$script" phase=before reboot=1 dmg=nightly)" || die "before failed: $out"
shutdown_called || die "before: no shutdown after the step: $(tail -3 "$calls")"
[[ "$(tail -1 "$calls")" == "sudo -n /sbin/shutdown -r now" ]] || die "before: the last command is not the shutdown: $(tail -3 "$calls")"
[[ "$(grep -c '^sudo -n /sbin/shutdown' "$calls")" == 1 ]] || die "before: want one shutdown"
grep -q '^probe open .* prime 6 term$' "$calls" || die "before: no priming launch: $(cat "$calls")"
grep -q '^LB-COPY reboot=1 installed=new version=0.1-123 cmux_bytes=3000 CmuxNextApp_bytes=5000 Chromium_Embedded_Framework_bytes=7000 path=' <<<"$out" \
  || die "before: LB-COPY: $out"
[[ "$(tail -1 <<<"$out")" == "LB-REBOOT reboot=1 left=0 in_s=0" ]] || die "before: LB-REBOOT is not the last row: $out"
: >"$calls"
out="$(bash "$script" phase=before reboot=2)" || die "before 2 failed"
grep -q '^LB-COPY reboot=2 installed=kept' <<<"$out" || die "before 2: the copy was not kept: $out"
shutdown_called || die "before 2: no shutdown"

# After, claimed before the reboot reached the host (kern.boottime unchanged): refused, nothing launched.
: >"$calls"
set +e; out="$(bash "$script" phase=after arm=noread reboot=2)"; rc=$?; set -e
if [[ $rc != 3 ]] || ! grep -q '^LB-FAIL reboot=2 not rebooted: kern.boottime is still the before step' <<<"$out"; then
  die "not rebooted: want LB-FAIL and exit 3, got $rc: $out"
fi
grep -q '^probe open' "$calls" && die "not rebooted: launched anyway"

# The shutdown's shell: from /, with only PATH in its environment, its outcome in ROOT/reboot.log.
grep -q '^asked=.* delay_s=0$' "$LB_ROOT/reboot.log" || die "reboot.log: no asked= line: $(cat "$LB_ROOT/reboot.log")"
grep -q '^shutdown_rc=0$' "$LB_ROOT/reboot.log" || die "reboot.log: no shutdown_rc: $(cat "$LB_ROOT/reboot.log")"
stub sudo '[[ "$2" == /sbin/shutdown ]] && { echo "cwd=$PWD"; env | grep -c "^CI_JOB_DIR=" ; } >"$(dirname "$0")/../shutdown-env"; exit 0'
: >"$calls"
CI_JOB_DIR=/step bash "$script" phase=before reboot=2 >/dev/null || die "before (env check) failed"
shutdown_called || die "before (env check): no shutdown"
for ((i = 0; i < 50; i++)); do [[ -s "$tmp/shutdown-env" ]] && break; /bin/sleep 0.1; done
[[ "$(cat "$tmp/shutdown-env" 2>/dev/null)" == $'cwd=/\n0' ]] || die "the shutdown's shell is not in / with CI_JOB_DIR gone: $(cat "$tmp/shutdown-env" 2>/dev/null)"
stub sudo 'exit 0'

# After, the boot older than 600 s: not a first launch after a reboot any more; refused, nothing launched.
: >"$calls"
set +e; out="$(FAKE_BOOT=$(($(date +%s) - 700)) bash "$script" phase=after arm=noread reboot=2)"; rc=$?; set -e
if [[ $rc != 3 ]] || ! grep -qE '^LB-FAIL reboot=2 booted too long ago: 70[0-4] s, over 600$' <<<"$out"; then
  die "old boot: want LB-FAIL and exit 3, got $rc: $out"
fi
grep -q '^probe open' "$calls" && die "old boot: launched anyway"

# After, arm=read, no loginwindow: s_since_login from kern.boottime (120 s ago).
: >"$calls"; rm -f "$tmp/ps-n"
out="$(FAKE_BOOT=$(($(date +%s) - 120)) bash "$script" phase=after arm=read reboot=3)" || die "after read failed: $out"
grep -q '^LB-REBOOT-LOG reboot=3 asked=' <<<"$out" || die "read: no LB-REBOOT-LOG: $out"
s="$(sed -n 's/^LB-LOGIN .*source=boot s_since_login=\([0-9]*\) .*/\1/p' <<<"$out")"
[[ -n "$s" && "$s" -ge 120 && "$s" -le 125 ]] || die "read: s_since_login from kern.boottime: $out"
[[ "$(grep -c '^LB-READ reboot=3 arm=read ' <<<"$out")" == 3 ]] || die "read: want 3 LB-READ rows: $out"
grep -q '^LB-READ .* file=Chromium_Embedded_Framework bytes=7000 wall_ms=120 cpu_ms=60 maxrss=1179648$' <<<"$out" || die "read: CEF row: $out"
grep -q '^LB-READ .* file=cmux bytes=3000 ' <<<"$out" || die "read: stub row: $out"
grep -q '^LB-LATE reboot=3 arm=read what=read target_s=5 ' <<<"$out" || die "read: the passed +5 s wait is not LB-LATE: $out"
grep -qE '^LB-LAUNCH arm=read reboot=3 s_since_login=1[2-9][0-9] request_to_start=45.1 main_start=120.2 first_frame=310.5 window_on_screen=420.7 settle=900.3 settle_by=window_usable pageins=4321 syspolicyd_ms=1000 xprotect_ms=100 amfid_ms=0 trustd_ms=0$' <<<"$out" \
  || die "read: LB-LAUNCH: $out"
grep -q '^probe open .* B 6 term$' "$calls" || die "read: no measured launch"
[[ "$(grep -c '^LB-RESIDENT reboot=3 arm=read t=prelaunch .* resident_pct=25.0 resident_pages=10 pages=40$' <<<"$out")" == 3 ]] || die "read: prelaunch residency: $out"

# Production-reader arm: runs exactly the bundle's helper, retains its report, measures the whole process.
reader="$LB_ROOT/copy/cmux NEXT.app/Contents/Resources/bin/cmux-launch-preread"
mkdir -p "$(dirname "$reader")"
printf '#!/usr/bin/env bash\necho "preread $*" >>"%s"\necho '\''{"bytes":15000,"stop":"done"}'\''\n' "$calls" >"$reader"
chmod +x "$reader"
: >"$calls"
out="$(FAKE_BOOT=$(($(date +%s) - 120)) bash "$script" phase=after arm=preread reboot=3)" || die "preread failed: $out"
grep -q '^preread $' "$calls" || die "preread: helper did not run with default caps"
grep -q '^LB-PREREAD .* wall_ms=120 cpu_ms=60 maxrss=1179648$' <<<"$out" || die "preread: cost row: $out"
grep -q '^LB-PREREAD-REPORT .* {"bytes":15000,"stop":"done"}$' <<<"$out" || die "preread: missing JSON: $out"
grep -q '^LB-READ ' <<<"$out" && die "preread: also ran uncapped cat"
chmod -x "$reader"
: >"$calls"
set +e; out="$(FAKE_BOOT=$(($(date +%s) - 120)) bash "$script" phase=after arm=preread reboot=3)"; rc=$?; set -e
[[ $rc == 3 && "$out" == *"no bundled cmux-launch-preread"* ]] || die "preread: absent reader accepted: $out"
grep -q '^probe open' "$calls" && die "preread: launched after missing reader"

# After, arm=noread: login from loginwindow's age (1 min 30 s), settle falls back to window + 6 s.
out="$(FAKE_BOOT=$(($(date +%s) - 200)) FAKE_LOGIN_ETIME=01:30 FAKE_NO_USABLE=1 bash "$script" phase=after arm=noread reboot=4)" || die "noread failed: $out"
grep -qE '^LB-LOGIN reboot=4 arm=noread source=loginwindow s_since_login=9[0-4] s_since_boot=20[0-4] login_after_boot_s=11[0-4] s_since_dock=120$' <<<"$out" \
  || die "noread: LB-LOGIN: $out"
grep -q '^LB-READ' <<<"$out" && die "noread: read the binaries: $out"
grep -q '^LB-LAUNCH arm=noread reboot=4 .* settle=6420.7 settle_by=window+6s ' <<<"$out" || die "noread: settle fallback: $out"

# After, arm=residency: the read, then residency at +1m, +10m and +60m, then the launch.
out="$(FAKE_BOOT=$(($(date +%s) - 2)) bash "$script" phase=after arm=residency reboot=11)" || die "residency failed: $out"
for t in +1m +10m +60m prelaunch; do
  [[ "$(grep -c "^LB-RESIDENT reboot=11 arm=residency t=$t " <<<"$out")" == 3 ]] || die "residency: want 3 rows at $t: $out"
done
[[ "$(grep -c '^LB-READ' <<<"$out")" == 3 ]] || die "residency: want the read: $out"
grep -q '^LB-LAUNCH arm=residency reboot=11 ' <<<"$out" || die "residency: no launch: $out"
grep -q '^LB-LATE' <<<"$out" && die "residency: waits in the future were LB-LATE: $out"

# The probe is there but the copy is gone.
rm -rf "$LB_ROOT/copy/cmux NEXT.app"
set +e; out="$(FAKE_BOOT=$(($(date +%s) - 100)) bash "$script" phase=after arm=read reboot=5)"; rc=$?; set -e
if [[ $rc != 3 ]] || ! grep -q '^LB-FAIL reboot=5 no copy in ' <<<"$out"; then die "no copy: want LB-FAIL and exit 3, got $rc: $out"; fi
grep -q '^LB-READ' <<<"$out" && die "no copy: read anyway: $out"
echo "launch-reboot: ok"
