#!/usr/bin/env bash
# Makes one perf lab host the same as the others. An operator runs it on the host:
#
#   ssh -t NODE 'cd CHECKOUT && sudo scripts/perf-lab/host-setup.sh --host NODE --bench-user USER [--grant-privileged]'
#   ssh -t NODE 'cd CHECKOUT && sudo scripts/perf-lab/host-setup.sh --host NODE --bench-user USER --check'
#
# It runs as root, --check too: the checks read the bench user's settings and ~/Library and root-only files. --check
# changes nothing; its vdisplay item still brings a virtual display up for 2 s. Prerequisite: Remote Login has
# "Allow full disk access for remote users" (System Settings > General > Sharing), because TCC keeps the Time Machine
# settings even from root; without it time-machine fails and says so.
#
# Each item prints one line: `ok ITEM: ...` (already so; nothing changed), `changed ITEM: ...`, `needs ITEM: ...`
# (--check: a run would change it) or `fail ITEM: ...`. A second run prints only ok lines and changes nothing.
# Exit 0 when no item failed or needs a change, 1 otherwise, 2 for a usage error.
#
# Items: pool-entry (NODE is a lab host in pool.json; its chip and memory match its host_class), power (pmset sleep,
# displaysleep and disksleep 0), spotlight (indexing off on the data volume), time-machine, auto-updates (macOS,
# security responses and App Store apps neither check, download nor install), auto-login (the bench user; asks for
# its password on the TTY), screen-lock (off for the bench user, screen saver idle 0), wpr
# (Web Page Replay, go.chromium.org/webpagereplay as Chrome's Telemetry uses it, at pool.json's pinned commit, built
# with Go in the bench user's Application Support), vdisplay-helper (scripts/ci/frame-pacing/vdisplay.m built there),
# vdisplay (a 120 Hz virtual display comes up for 2 s in the bench user's console session) and sudoers.
#
# sudoers (decision D3): with --grant-privileged, /etc/sudoers.d/cmux-perf-lab lets the bench user run exactly the
# argv lists in pool.json `privileged` (purge with no arguments, one fixed powermetrics command line: any free argument
# list would allow `powermetrics -o FILE`, a root-owned write; its fixed `-n` count ends it by itself, as the bench user
# cannot signal a root sampler its killed job left). Without the flag that file is removed. The script never touches
# SSH keys, Tailscale, user accounts, FileVault or any other host access.
#
# --root DIR is the test seam: every macOS tool and system file is looked up under DIR (tests/test_host_setup.py).
set -uo pipefail

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "host-setup.sh: $*" >&2; exit 2; }
need() { (( $# >= 2 )) && [[ -n "$2" ]] || die "$1 needs a value"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
pool="$here/pool.json"
host=""; bench=""; grant=0; check_only=0; root=""
while (( $# )); do
  case "$1" in
    --host) need "$@"; host="$2"; shift 2 ;;
    --bench-user) need "$@"; bench="$2"; shift 2 ;;
    --grant-privileged) grant=1; shift ;;
    --check) check_only=1; shift ;;
    --pool) need "$@"; pool="$2"; shift 2 ;;
    --root) need "$@"; root="$2"; [[ -d "$root" ]] || die "--root takes an existing directory"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "host-setup.sh: unknown argument $1" >&2; usage ;;
  esac
done
[[ -n "$host" ]] || die "--host NODE is required (its pool.json name)"
[[ "$bench" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--bench-user USER is required (a short user name)"
[[ -n "$root" || "$(uname -s)" == Darwin ]] || die "lab hosts are Macs"

# A macOS tool, under --root in tests.
c() { local tool="$1"; shift; "$root$tool" "$@"; }
[[ "$(c /usr/bin/id -u)" == 0 ]] || die "run it with sudo, --check too: it reads the bench user's settings and root-only files"
# A command as the bench user.
as_bench() { c /usr/bin/sudo -n -u "$bench" -H "$@"; }

pool_vars="$(/usr/bin/python3 -I - "$pool" "$host" "$bench" <<'PY'
import json, re, shlex, sys

pool_path, host, bench = sys.argv[1:]
EXPECTED = {"purge": "/usr/sbin/purge", "powermetrics": "/usr/bin/powermetrics"}
try:
    pool = json.load(open(pool_path, encoding="utf-8"))
    entry = next((h for h in pool["hosts"] if h["name"] == host), None)
    if entry is None:
        sys.exit(f"{host} is not a lab host in {pool_path}")
    privileged = pool["privileged"]
    if set(privileged) != set(EXPECTED):
        sys.exit(f"privileged must name exactly {sorted(EXPECTED)} (decision D3)")
    rules = [f"# cmux perf lab (p12-perf-process-130, decision D3): {bench} may run these exact commands as root."]
    for name in sorted(privileged):
        argv = privileged[name]
        if argv[0] != EXPECTED[name] or not all(re.fullmatch(r"[A-Za-z0-9_.,/-]+", a) for a in argv):
            sys.exit(f"privileged.{name}: {argv!r} is not {EXPECTED[name]} with plain arguments")
        args = " ".join(a.replace(",", "\\,") for a in argv[1:]) or '""'
        rules.append(f"{bench} ALL=(root) NOPASSWD: {argv[0]} {args}")
    values = {"host_class": entry["host_class"], "wpr_repo": pool["wpr"]["repo"],
              "wpr_commit": pool["wpr"]["commit"], "sudoers_text": "\n".join(rules)}
except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
    sys.exit(f"{pool_path}: {error!r}")
if not re.fullmatch(r"[0-9a-f]{40}", values["wpr_commit"]):
    sys.exit("wpr.commit must be a full commit sha")
for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
)" || die "cannot use $pool"
host_class=""; wpr_repo=""; wpr_commit=""; sudoers_text=""
eval "$pool_vars"

bench_home="$(c /usr/bin/dscl . -read "/Users/$bench" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$bench_home" ]] || die "there is no user $bench (this script does not create users)"
support="$bench_home/Library/Application Support/cmux-perf-lab"
sudoers_file="$root/etc/sudoers.d/cmux-perf-lab"
data_volume=/System/Volumes/Data
vdisplay_digest="$(cat "$repo/scripts/ci/frame-pacing/vdisplay.m" "$repo/scripts/ci/frame-pacing/VDisplay-Info.plist" \
  | c /usr/bin/shasum -a 256 | cut -c1-16)"
vdisplay_app="$support/vdisplay/$vdisplay_digest/VDisplay.app"

failed=0
say() {
  printf '%s %s: %s\n' "$1" "$2" "$3"
  [[ "$1" == ok || "$1" == changed ]] || failed=1
}
# item NAME CHECK [APPLY]: CHECK prints why and succeeds when the host already is right, returns 1 when APPLY would
# change it and 2 when it cannot read the state (then APPLY does not run).
item() {
  local name="$1" check="$2" apply="${3:-}" why status
  why="$("$check")"; status=$?
  if (( status == 0 )); then say ok "$name" "$why"; return; fi
  if (( status == 2 )) || [[ -z "$apply" ]]; then say fail "$name" "$why"; return; fi
  if (( check_only )); then say needs "$name" "$why"; return; fi
  if ! "$apply" >&2; then say fail "$name" "$why"; return; fi
  if why="$("$check")"; then say changed "$name" "$why"; else say fail "$name" "still: $why"; fi
}
pref() { c /usr/bin/defaults read "$1" "$2" 2>/dev/null; }

check_pool_entry() {
  local chip memory have
  chip="$(c /usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  memory="$(c /usr/sbin/sysctl -n hw.memsize 2>/dev/null)"
  [[ -n "$chip" && "$memory" =~ ^[0-9]+$ ]] || { echo "sysctl gave no chip or memory"; return 1; }
  have="$(tr 'A-Z ' 'a-z-' <<<"$chip")/$(( (memory + 2**29) / 2**30 ))gb"
  [[ "${host_class%/*}" == "$have" ]] && { echo "$host is $host_class"; return 0; }
  echo "pool.json says $host is $host_class, but this host is $have; fix pool.json"; return 1
}

check_power() {
  local out key value bad=""
  out="$(c /usr/bin/pmset -g 2>&1)" || { echo "pmset -g failed"; return 1; }
  for key in sleep displaysleep disksleep; do
    value="$(awk -v k="$key" '$1 == k { print $2; exit }' <<<"$out")"
    [[ "$value" == 0 ]] || bad+=" $key=${value:-unset}"
  done
  [[ -z "$bad" ]] && { echo "sleep, displaysleep and disksleep are 0"; return 0; }
  echo "pmset:$bad"; return 1
}
apply_power() { c /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0; }

check_spotlight() {
  local out
  out="$(c /usr/bin/mdutil -s "$data_volume" 2>&1)"
  grep -Eq 'Indexing (and searching )?disabled' <<<"$out" && { echo "indexing is off on $data_volume"; return 0; }
  echo "mdutil -s: $(tr '\n\t' '  ' <<<"$out")"; return 1
}
apply_spotlight() { c /usr/bin/mdutil -i off "$data_volume"; }

time_machine=/Library/Preferences/com.apple.TimeMachine
check_time_machine() {
  local err
  if [[ -e "$root$time_machine.plist" ]] && ! err="$(c /bin/cat "$root$time_machine.plist" 2>&1 >/dev/null)"; then
    echo "cannot read $time_machine.plist (${err##*: }): give sshd Full Disk Access (System Settings > General >" \
      "Sharing > Remote Login > Allow full disk access for remote users)"
    return 2
  fi
  [[ "$(pref "$time_machine" AutoBackup)" == 0 ]] && { echo "automatic backups are off"; return 0; }
  echo "Time Machine backs up automatically"; return 1
}
apply_time_machine() { c /usr/bin/tmutil disable; }

# CriticalUpdateInstall and ConfigDataInstall are "Install Security Responses and system files" (XProtect, Rapid
# Security Responses); AutomaticallyInstallAppUpdates is App Store apps since macOS 13, com.apple.commerce before.
update_prefs="/Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled
/Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload
/Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates
/Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall
/Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall
/Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallAppUpdates
/Library/Preferences/com.apple.commerce AutoUpdate"
check_auto_updates() {
  local domain key on=""
  while read -r domain key; do
    [[ "$(pref "$domain" "$key")" == 0 ]] || on+=" ${domain##*/}.$key"
  done <<<"$update_prefs"
  [[ -z "$on" ]] && { echo "macOS, security response and App Store updates neither check, download nor install"; return 0; }
  echo "still on:$on"; return 1
}
apply_auto_updates() {
  local domain key
  while read -r domain key; do
    [[ "$(pref "$domain" "$key")" == 0 ]] || c /usr/bin/defaults write "$domain" "$key" -bool false || return 1
  done <<<"$update_prefs"
}

check_auto_login() {
  local user
  user="$(pref /Library/Preferences/com.apple.loginwindow autoLoginUser)"
  [[ "$user" == "$bench" && -f "$root/etc/kcpassword" ]] && { echo "$bench logs in at boot"; return 0; }
  echo "the auto-login user is ${user:-not set}, not $bench"; return 1
}
apply_auto_login() {
  if c /usr/bin/fdesetup status 2>/dev/null | grep -q 'FileVault is On'; then
    echo "host-setup.sh: FileVault is on, so macOS refuses auto-login; this script does not change FileVault"; return 1
  fi
  echo "host-setup.sh: the password of $bench, for auto-login:"
  c /usr/sbin/sysadminctl -autologin set -userName "$bench" -password -
}

check_screen_lock() {
  local lock idle
  lock="$(as_bench "$root/usr/sbin/sysadminctl" -screenLock status 2>&1)"
  idle="$(as_bench "$root/usr/bin/defaults" -currentHost read com.apple.screensaver idleTime 2>/dev/null)"
  if grep -q 'screenLock is off' <<<"$lock" && [[ "$idle" == 0 ]]; then
    echo "no screen lock and no screen saver for $bench"; return 0
  fi
  echo "screen lock: $(tail -n 1 <<<"$lock" | sed 's/.*\] //'); screen saver idleTime ${idle:-not set}"; return 1
}
apply_screen_lock() {
  echo "host-setup.sh: the password of $bench, to turn its screen lock off:"
  as_bench "$root/usr/sbin/sysadminctl" -screenLock off -password - \
    && as_bench "$root/usr/bin/defaults" -currentHost write com.apple.screensaver idleTime -int 0
}

wpr_dir="$support/wpr/$wpr_commit"
check_wpr() {
  [[ -x "$wpr_dir/wpr" && "$(cat "$wpr_dir/.cmux-perf-lab-commit" 2>/dev/null)" == "$wpr_commit" ]] \
    && { echo "$wpr_dir/wpr"; return 0; }
  echo "wpr ${wpr_commit:0:12} is not built"; return 1
}
apply_wpr() {
  local go="" candidate tmp="$support/wpr/.build-$$"
  for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
    [[ -x "$root$candidate" ]] && { go="$root$candidate"; break; }
  done
  [[ -n "$go" ]] || { echo "host-setup.sh: Go is not installed (brew install go)"; return 1; }
  as_bench /bin/rm -rf "$tmp" && as_bench /bin/mkdir -p "$tmp" \
    && as_bench "$root/usr/bin/git" -C "$tmp" init -q \
    && as_bench "$root/usr/bin/git" -C "$tmp" fetch -q --depth 1 "$wpr_repo" "$wpr_commit" \
    && as_bench "$root/usr/bin/git" -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD \
    && as_bench "$go" -C "$tmp" build -trimpath -o wpr ./src/wpr.go \
    && as_bench /bin/sh -c 'printf "%s\n" "$1" > "$2/.cmux-perf-lab-commit"' sh "$wpr_commit" "$tmp" \
    && as_bench /bin/rm -rf "$wpr_dir" && as_bench /bin/mv "$tmp" "$wpr_dir" \
    || { as_bench /bin/rm -rf "$tmp"; return 1; }
}

check_vdisplay_helper() {
  [[ -x "$vdisplay_app/Contents/MacOS/VDisplay" ]] && { echo "$vdisplay_app"; return 0; }
  echo "VDisplay.app for vdisplay.m $vdisplay_digest is not built"; return 1
}
apply_vdisplay_helper() {
  local tmp="$support/vdisplay/.build-$$/VDisplay.app"
  as_bench /bin/mkdir -p "$tmp/Contents/MacOS" \
    && as_bench "$root/usr/bin/xcrun" clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit \
      -framework CoreVideo "$repo/scripts/ci/frame-pacing/vdisplay.m" -o "$tmp/Contents/MacOS/VDisplay" \
    && as_bench /bin/cp "$repo/scripts/ci/frame-pacing/VDisplay-Info.plist" "$tmp/Contents/Info.plist" \
    && as_bench "$root/usr/bin/codesign" -s - --force "$tmp" \
    && as_bench /bin/mkdir -p "${vdisplay_app%/*}" && as_bench /bin/rm -rf "$vdisplay_app" \
    && as_bench /bin/mv "$tmp" "$vdisplay_app"
  local status=$?
  as_bench /bin/rm -rf "$support/vdisplay/.build-$$"
  return "$status"
}

check_vdisplay() {
  local console out p50
  [[ -x "$vdisplay_app/Contents/MacOS/VDisplay" ]] || { echo "the helper is not built"; return 1; }
  console="$(c /usr/bin/stat -f %Su /dev/console 2>/dev/null)"
  [[ "$console" == "$bench" ]] \
    || { echo "the console user is ${console:-nobody}, not $bench; reboot so auto-login takes effect"; return 1; }
  out="$(c /bin/launchctl asuser "$(c /usr/bin/id -u "$bench")" "$root/usr/bin/sudo" -u "$bench" \
    "$vdisplay_app/Contents/MacOS/VDisplay" 120 2 2>&1)"
  p50="$(sed -n 's/^ready [0-9]* \([0-9.]*\).*/\1/p' <<<"$out" | head -n 1)"
  [[ -n "$p50" ]] || { echo "no ready line: $(head -n 2 <<<"$out" | tr '\n' ' ')"; return 1; }
  echo "a 120 Hz virtual display came up, CVDisplayLink p50 $p50 ms (task 160 decides hz=120 or hz=60)"
}

check_sudoers() {
  if (( grant )); then
    [[ -f "$sudoers_file" && "$(cat "$sudoers_file")" == "$sudoers_text" ]] \
      && { echo "$bench may run only pool.json's purge and powermetrics command lines"; return 0; }
    echo "${sudoers_file#"$root"} does not hold exactly pool.json's privileged commands"; return 1
  fi
  [[ ! -e "$sudoers_file" ]] && { echo "no lab sudoers entries (no --grant-privileged)"; return 0; }
  echo "${sudoers_file#"$root"} exists without --grant-privileged"; return 1
}
apply_sudoers() {
  (( grant )) || { rm -f "$sudoers_file"; return; }
  [[ -d "${sudoers_file%/*}" ]] || { echo "host-setup.sh: no ${sudoers_file%/*} directory"; return 1; }
  # sudo's #includedir skips names that contain a dot, so the half-written file is never live.
  local tmp="${sudoers_file%/*}/.cmux-perf-lab.$$"
  (umask 077 && printf '%s\n' "$sudoers_text" >"$tmp") && chmod 0440 "$tmp" \
    && c /usr/sbin/chown root:wheel "$tmp" && c /usr/sbin/visudo -cf "$tmp" && mv -f "$tmp" "$sudoers_file" \
    || { rm -f "$tmp"; return 1; }
}

item pool-entry check_pool_entry
item power check_power apply_power
item spotlight check_spotlight apply_spotlight
item time-machine check_time_machine apply_time_machine
item auto-updates check_auto_updates apply_auto_updates
item auto-login check_auto_login apply_auto_login
item screen-lock check_screen_lock apply_screen_lock
item wpr check_wpr apply_wpr
item vdisplay-helper check_vdisplay_helper apply_vdisplay_helper
item vdisplay check_vdisplay
item sudoers check_sudoers apply_sudoers
exit "$failed"
