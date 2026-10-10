#!/usr/bin/env bash
# macOS launch smoke for a cmux-next build on each supported major (14 Sonoma,
# 15 Sequoia, 26 Tahoe), in disposable Tart VMs. Run it ON a Tart host (a fleet
# Mac with hv_support=1), never on a laptop.
#
# For each major in images.json (pinned by digest): pull the base image if it is
# missing, take the fleet host lock exclusively, clone, boot headless
# (--no-graphics), copy the build in, run guest-probe.py over SSH (launch with
# CMUX_NEXT_NO_ACTIVATE=1 and CMUX_NEXT_SOCKET_MODE=automation, wait for the
# first window and the control socket, open one terminal and one browser tab,
# debug.window_snapshot, quit), copy the artifacts out, stop and delete the
# clone, release the lock. Base images stay. Majors run one at a time (the
# Apple license allows at most two macOS VMs per host).
#
# Usage: run.sh [--majors 14,15,26] [--work DIR] [--keep-vm] BUILD
#   BUILD    a cmux-next .app or a zip that contains one (cmux-ci artifact).
#   --work   state root (default /Volumes/ephemeral0/cmux-agent-work/mfloor).
#   --keep-vm  leave the clone stopped but not deleted (debugging only).
# Env: TART_BIN (default: tart on PATH, else <work>/tools/tart-*/tart.app),
#   TART_HOME (default <work>/tart-home), OS_SMOKE_HOST_LOCK (default
#   /Users/Shared/cmux-build-fleet/host.lock when present; "none" disables),
#   OS_SMOKE_BOOT_DEADLINE (s, default 300), OS_SMOKE_LAUNCH_DEADLINE and
#   OS_SMOKE_TAB_DEADLINE (s, passed to the guest), OS_SMOKE_KEYCHAIN_PASSWORD_FILE
#   (0600 file with the host user's login password: unlocks the login
#   keychain for each cycle when it is locked, relocks after).
# Session: Virtualization.framework needs the login keychain. Run from a GUI
#   session or an OpenSSH session (on a fleet AWS Mac: an SSH localhost
#   session); a Tailscale SSH session has no keychain search list.
# Guest login admin/admin is the public default of the cirruslabs images.
# Prints a per-major PASS/FAIL table and the artifacts dir; exits 1 on any FAIL.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAJORS=14,15,26
WORK=${OS_SMOKE_WORK:-/Volumes/ephemeral0/cmux-agent-work/mfloor}
KEEP_VM=0
CYCLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --majors) MAJORS=$2; shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --keep-vm) KEEP_VM=1; shift ;;
    --vm-cycle) CYCLE=$2; shift 2 ;;  # internal: one major, already under the host lock
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) BUILD=$1; shift ;;
  esac
done

export TART_HOME=${TART_HOME:-$WORK/tart-home}
if [[ -z "${TART_BIN:-}" ]]; then
  TART_BIN=$(command -v tart || ls -d "$WORK"/tools/tart-*/tart.app/Contents/MacOS/tart 2>/dev/null | tail -1 || true)
fi
[[ -x "${TART_BIN:-}" ]] || { echo "no tart binary: install it (images.json names the release) or set TART_BIN" >&2; exit 2; }
export TART_BIN
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5
  -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1)

image_field() {  # image_field MAJOR FIELD
  python3 -I -c 'import json,sys
for i in json.load(open(sys.argv[1]))["images"]:
    if i["major"] == sys.argv[2]: print(i[sys.argv[3]]); break
else: sys.exit("major %s is not in images.json" % sys.argv[2])' "$HERE/images.json" "$1" "$2"
}

now() { python3 -I -c 'import time; print(f"{time.time():.1f}")'; }
elapsed() { python3 -I -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.1f}")' "$1" "$2"; }

# ---- one major, inside the host lock ---------------------------------------
if [[ -n "$CYCLE" ]]; then
  : "${RUN_DIR:?}" "${BUILD_ZIP:?}"
  major=$CYCLE
  out="$RUN_DIR/$major"
  mkdir -p "$out"
  source_ref="$(image_field "$major" ref)@$(image_field "$major" digest)"
  vm="os-smoke-$major-$$"
  askpass="$RUN_DIR/askpass.sh"
  export SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none
  tart_pid=""
  ip=""
  record() { printf '%s=%s\n' "$1" "$2" >>"$out/host.env"; }
  # Virtualization.framework keeps a host key in the login keychain: Tart
  # fails with "Failed to get current host key" when the session has no
  # keychain search list (Tailscale SSH) or the keychain is locked (OpenSSH
  # without a GUI login). Unlock it for this cycle only, relock at exit.
  keychain=$HOME/Library/Keychains/login.keychain-db
  relock=0
  [[ -n "$(security default-keychain 2>/dev/null)" ]] || {
    record failure "no default keychain in this session (Tailscale SSH?); run from an OpenSSH or GUI session"; exit 1; }
  if ! security show-keychain-info "$keychain" >/dev/null 2>&1; then
    [[ -r "${OS_SMOKE_KEYCHAIN_PASSWORD_FILE:-}" ]] || {
      record failure "login keychain locked; set OS_SMOKE_KEYCHAIN_PASSWORD_FILE"; exit 1; }
    security unlock-keychain "$keychain" <"$OS_SMOKE_KEYCHAIN_PASSWORD_FILE" >/dev/null 2>&1 || {
      record failure "login keychain unlock failed"; exit 1; }
    relock=1
  fi
  cleanup() {
    [[ "$relock" == 1 ]] && security lock-keychain "$keychain" || true
    if "$TART_BIN" list --source local --quiet 2>/dev/null | grep -qx "$vm"; then
      "$TART_BIN" stop "$vm" --timeout 30 >/dev/null 2>&1 || true
      [[ -n "$tart_pid" ]] && wait "$tart_pid" 2>/dev/null || true
      if [[ "$KEEP_VM" == 1 ]]; then echo "kept stopped clone $vm" >&2; else "$TART_BIN" delete "$vm" >/dev/null 2>&1 || true; fi
    fi
  }
  trap cleanup EXIT
  gssh() { ssh "${SSH_OPTS[@]}" "admin@$ip" "$@" </dev/null; }
  t0=$(now)
  "$TART_BIN" clone "$source_ref" "$vm"
  t_clone=$(now); record clone_s "$(elapsed "$t0" "$t_clone")"
  "$TART_BIN" run --no-graphics "$vm" >"$out/tart-run.log" 2>&1 &
  tart_pid=$!
  ip=$("$TART_BIN" ip "$vm" --wait "${OS_SMOKE_BOOT_DEADLINE:-300}") || { record failure "no guest IP"; exit 1; }
  # sshd starts after DHCP: bounded poll with a deadline, stops if tart exits.
  deadline=$(( $(date +%s) + ${OS_SMOKE_BOOT_DEADLINE:-300} ))
  until gssh true 2>/dev/null; do
    kill -0 "$tart_pid" 2>/dev/null || { record failure "tart run exited during boot"; exit 1; }
    (( $(date +%s) < deadline )) || { record failure "guest SSH not up before the deadline"; exit 1; }
    sleep 2
  done
  t_boot=$(now); record boot_s "$(elapsed "$t_clone" "$t_boot")"
  scp "${SSH_OPTS[@]}" -q "$BUILD_ZIP" "$HERE/guest-probe.py" "admin@$ip:/Users/admin/" </dev/null
  gssh 'set -e; rm -rf ~/smoke && mkdir -p ~/smoke/app && ditto -x -k ~/build.zip ~/smoke/app && test -x /usr/bin/python3 && /usr/bin/python3 -c 1'
  t_copy=$(now); record copy_s "$(elapsed "$t_boot" "$t_copy")"
  probe_rc=0
  gssh "app=\$(ls -d ~/smoke/app/*.app | head -1); OS_SMOKE_LAUNCH_DEADLINE=${OS_SMOKE_LAUNCH_DEADLINE:-180} OS_SMOKE_TAB_DEADLINE=${OS_SMOKE_TAB_DEADLINE:-120} /usr/bin/python3 -I ~/guest-probe.py \"\$app\" ~/smoke/out" \
    >"$out/probe.log" 2>&1 || probe_rc=$?
  record probe_exit "$probe_rc"
  scp "${SSH_OPTS[@]}" -q -r "admin@$ip:/Users/admin/smoke/out/." "$out/" </dev/null || record failure "artifact copy failed"
  t_probe=$(now); record probe_s "$(elapsed "$t_copy" "$t_probe")"
  exit 0
fi

# ---- driver -----------------------------------------------------------------
[[ -n "${BUILD:-}" && -e "$BUILD" ]] || { echo "usage: run.sh [--majors 14,15,26] [--work DIR] BUILD(.app|.zip)" >&2; exit 2; }
LOCK=${OS_SMOKE_HOST_LOCK:-/Users/Shared/cmux-build-fleet/host.lock}
[[ "$LOCK" == none || -e "$LOCK" ]] || LOCK=none
export RUN_DIR="$WORK/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$RUN_DIR"
printf '#!/bin/sh\necho admin\n' >"$RUN_DIR/askpass.sh"
chmod 700 "$RUN_DIR/askpass.sh"
case "$BUILD" in
  *.zip) export BUILD_ZIP=$(cd "$(dirname "$BUILD")" && pwd)/$(basename "$BUILD") ;;
  *.app|*.app/) export BUILD_ZIP="$RUN_DIR/build.zip"; ditto -c -k --keepParent "$BUILD" "$BUILD_ZIP" ;;
  *) echo "BUILD must be a .app or a .zip" >&2; exit 2 ;;
esac
# scp keeps the basename; the cycle expects ~/build.zip in the guest.
if [[ "$(basename "$BUILD_ZIP")" != build.zip ]]; then ln -sf "$BUILD_ZIP" "$RUN_DIR/build.zip"; export BUILD_ZIP="$RUN_DIR/build.zip"; fi
shasum -a 256 -b "$(readlink "$BUILD_ZIP" || echo "$BUILD_ZIP")" | cut -d' ' -f1 >"$RUN_DIR/build.sha256"
"$TART_BIN" --version >"$RUN_DIR/tart.version"

IFS=, read -r -a majors <<<"$MAJORS"
for major in "${majors[@]}"; do
  out="$RUN_DIR/$major"; mkdir -p "$out"
  ref=$(image_field "$major" ref); digest=$(image_field "$major" digest)
  t0=$(now)
  if ! "$TART_BIN" list --source oci --format json | python3 -I -c 'import json,sys
sys.exit(0 if any(sys.argv[1] in v.get("Name", "") for v in json.load(sys.stdin)) else 1)' "$digest"; then
    echo "pulling $ref@$digest"
    "$TART_BIN" pull "$ref@$digest" >"$out/pull.log" 2>&1 || { echo "failure=pull failed" >>"$out/host.env"; continue; }
  fi
  t1=$(now); echo "pull_s=$(elapsed "$t0" "$t1")" >>"$out/host.env"
  oci_dir="$TART_HOME/cache/OCIs/${ref}/${digest}"
  echo "image_disk_kb=$(du -sk "$(readlink "$oci_dir" || echo "$oci_dir")" 2>/dev/null | cut -f1)" >>"$out/host.env"
  echo "== macOS $major: waiting for the host lock" >&2
  cycle=("$0" --vm-cycle "$major" --work "$WORK")
  [[ "$KEEP_VM" == 1 ]] && cycle+=(--keep-vm)
  rc=0
  if [[ "$LOCK" == none ]]; then
    "${cycle[@]}" || rc=$?
  else
    # Exclusive fleet host lock (FLEET-HEALTH.md recipe); held only for clone..delete.
    perl -MFcntl=:flock -MTime::HiRes=time -e 'open(my $f, ">>", shift) or die "lock: $!"; my $t = time; flock($f, LOCK_EX) or die "flock: $!";
      printf STDERR "host lock after %.1f s\n", time - $t; open(my $o, ">>", shift); printf $o "lock_wait_s=%.1f\n", time - $t; close $o;
      exit(system(@ARGV) >> 8)' "$LOCK" "$out/host.env" "${cycle[@]}" || rc=$?
  fi
  echo "cycle_exit=$rc" >>"$out/host.env"
  echo "total_s=$(elapsed "$t0" "$(now)")" >>"$out/host.env"
done

python3 -I - "$RUN_DIR" "$MAJORS" <<'PY'
import json, os, sys
run, majors = sys.argv[1], sys.argv[2].split(",")
rows, failed = [], False
for m in majors:
    d = os.path.join(run, m)
    env = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.join(d, "host.env")) if "=" in l) if os.path.exists(os.path.join(d, "host.env")) else {}
    res = json.load(open(os.path.join(d, "result.json"))) if os.path.exists(os.path.join(d, "result.json")) else {}
    ok = bool(res.get("ok")) and env.get("cycle_exit") == "0"
    failed |= not ok
    why = env.get("failure") or ",".join(res.get("failed_steps", [])) or ("" if res else "no result.json")
    launch = (res.get("steps", {}).get("launch") or {}).get("detail") or {}
    if isinstance(launch, dict) and launch.get("dyld"):
        why += ": " + launch["dyld"][0].strip()[:160]
    ls = res.get("launchservices")
    rows.append((m, res.get("guest_os", "?"), "PASS" if ok else "FAIL", env.get("boot_s", "-"), str(res.get("launch_seconds", "-")),
                 env.get("total_s", "-"), env.get("image_disk_kb", "-"), why + (" | open exit %s" % ls["exit"] if ls else "")))
print("\n%-5s %-8s %-5s %7s %8s %7s %12s  %s" % ("major", "guest", "res", "boot_s", "launch_s", "total_s", "image_kb", "failure"))
for r in rows:
    print("%-5s %-8s %-5s %7s %8s %7s %12s  %s" % r)
print("artifacts: %s" % run)
sys.exit(1 if failed else 0)
PY
