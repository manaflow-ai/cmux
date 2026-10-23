#!/usr/bin/env bash
# UI fuzz of one cmux-next build on each supported macOS major, in disposable Tart VMs.
# Run it ON a Tart host, never on a laptop.
#
# Usage: vm.sh [--majors 14,15,26] [--seed N] [--steps N] [--work DIR] [--keep-vm] BUILD
#   BUILD   a cmux-next .app, a .zip with one, or a .dmg (a shipped nightly).
# Images, Tart, TART_HOME, the fleet host lock and the keychain rules are defined
# by this fuzzer's images.json and the host environment.
# For each major: clone the pinned image, boot headless with Virtualization.framework's
# VNC server, copy the build in, run fuzz.py (input over VNC, CLI over SSH), copy the
# findings out, stop and delete the clone. Majors run one at a time under the host lock.
# Output: <work>/fuzz/<UTC>-<pid>/<major>/{summary.json,steps.jsonl,findings.jsonl,*.ips,...}
# and <run>/matrix.json. Exit 1 when any major found a crash, hang or dead app.
# Replay a finding: --replay <run>/<major>/steps.jsonl (same build, same major).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGES="$HERE/images.json"
MAJORS=14,15,26; SEED=1; STEPS=600; KEEP_VM=0; REPLAY=""
WORK=${FUZZ_WORK:-/Volumes/ephemeral0/cmux-agent-work/mfloor}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --majors) MAJORS=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --steps) STEPS=$2; shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --replay) REPLAY=$2; shift 2 ;;
    --keep-vm) KEEP_VM=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) BUILD=$1; shift ;;
  esac
done
[[ -n "${BUILD:-}" && -e "$BUILD" ]] || { echo "usage: vm.sh [--majors 14,15,26] BUILD" >&2; exit 2; }
export TART_HOME=${TART_HOME:-$WORK/tart-home}
TART_BIN=${TART_BIN:-$(command -v tart || ls -d "$WORK"/tools/tart-*/tart.app/Contents/MacOS/tart 2>/dev/null | tail -1 || true)}
[[ -x "$TART_BIN" ]] || { echo "no tart binary (see images.json)" >&2; exit 2; }
LOCK=${FUZZ_HOST_LOCK:-/Users/Shared/cmux-build-fleet/host.lock}
[[ "$LOCK" == none || -e "$LOCK" ]] || LOCK=none
CURRENT_VM=""
# A failing command under set -e skips the RETURN trap: stop and delete the clone at exit too.
trap '[[ -n "$CURRENT_VM" ]] && { "$TART_BIN" stop "$CURRENT_VM" --timeout 30 >/dev/null 2>&1; [[ "$KEEP_VM" == 1 ]] || "$TART_BIN" delete "$CURRENT_VM" >/dev/null 2>&1; }; true' EXIT
RUN="$WORK/fuzz/$(date -u +%Y%m%dT%H%M%SZ)-$$"; mkdir -p "$RUN"
printf '#!/bin/sh\necho admin\n' >"$RUN/askpass.sh"; chmod 700 "$RUN/askpass.sh"
export SSH_ASKPASS="$RUN/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=none
SSH_OPTS=(-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1)
SSHB=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "${SSH_OPTS[@]}")

image_ref() {  # FUZZ_IMAGE_<major> (e.g. ghcr.io/cirruslabs/macos-sonoma-vanilla:14.8.7) overrides the pin
  local override; override=$(eval "echo \${FUZZ_IMAGE_$1:-}")
  [[ -n "$override" ]] && { echo "$override"; return; }
  python3 -I -c 'import json,sys
for i in json.load(open(sys.argv[1]))["images"]:
    if i["major"] == sys.argv[2]: print(i["ref"] + "@" + i["digest"]); break
else: sys.exit("major %s is not in images.json" % sys.argv[2])' "$IMAGES" "$1"; }

cycle() {  # cycle MAJOR OUT
  local major=$1 out=$2 vm="fuzz-$1-$$" tart_pid="" ip=""
  local ref; ref=$(image_ref "$major")
  "$TART_BIN" list --source oci --quiet 2>/dev/null | grep -qF "${ref##*[@]}" || "$TART_BIN" pull "$ref" >"$out/pull.log" 2>&1
  cleanup_vm() {
    "$TART_BIN" stop "$vm" --timeout 30 >/dev/null 2>&1 || true
    [[ -n "$tart_pid" ]] && wait "$tart_pid" 2>/dev/null || true
    [[ "$KEEP_VM" == 1 ]] || "$TART_BIN" delete "$vm" >/dev/null 2>&1 || true
  }
  trap cleanup_vm RETURN
  trap 'cleanup_vm; exit 130' INT TERM
  CURRENT_VM=$vm
  "$TART_BIN" clone "$ref" "$vm"
  "$TART_BIN" set "$vm" --display 1440x900 >/dev/null 2>&1 || true
  "$TART_BIN" run --no-graphics --vnc-experimental "$vm" >"$out/tart-run.log" 2>&1 &
  tart_pid=$!
  ip=$("$TART_BIN" ip "$vm" --wait 300)
  local deadline=$(( $(date +%s) + 300 ))
  until ssh "${SSHB[@]}" "admin@$ip" true </dev/null 2>/dev/null; do
    kill -0 "$tart_pid" 2>/dev/null || { echo "tart exited during boot" >"$out/failure"; return 1; }
    (( $(date +%s) < deadline )) || { echo "no guest SSH" >"$out/failure"; return 1; }
    sleep 2
  done
  local vnc; vnc=$(grep -Eo 'vnc://[^ ]+' "$out/tart-run.log" | head -1)
  local vncarg; vncarg=$(python3 -I -c 'import sys,urllib.parse as u;p=u.urlparse(sys.argv[1]);print("%s:%s:%s"%(p.hostname,p.port,u.unquote(p.password or "")))' "$vnc")
  scp "${SSHB[@]}" -q "$BUILD_ZIP" "admin@$ip:/Users/admin/build.zip" </dev/null
  local app; app=$(ssh "${SSHB[@]}" "admin@$ip" 'set -e; pkill -x "System Settings" || true; pkill -x Terminal || true; rm -rf ~/fuzzapp; mkdir ~/fuzzapp;
    ditto -x -k ~/build.zip ~/fuzzapp; ls -d ~/fuzzapp/*.app | head -1' </dev/null)
  local rargs=(); if [[ -n "$REPLAY" ]]; then rargs=(--replay "$REPLAY"); fi
  if [[ -n "${FUZZ_DYLIB:-}" ]]; then
    # Diagnostics only: a dylib loaded with DYLD_INSERT_LIBRARIES, which the hardened runtime
    # refuses, so the guest copy of the app is re-signed ad hoc without it.
    scp "${SSHB[@]}" -q "$FUZZ_DYLIB" "admin@$ip:/Users/admin/fuzz-diag.dylib" </dev/null
    ssh "${SSHB[@]}" "admin@$ip" "codesign --force --deep --sign - $(printf %q "$app") >/dev/null 2>&1" </dev/null
    rargs+=(--insert-dylib /Users/admin/fuzz-diag.dylib)
  fi
  python3 -I "$HERE/fuzz.py" --ssh "admin@$ip" --vnc "$vncarg" --app "$app" --seed "$SEED" --steps "$STEPS" \
    --out "$out" ${rargs[@]+"${rargs[@]}"} ${FUZZ_ARGS:-} --ssh-opt=-oPubkeyAuthentication=no \
    --ssh-opt=-oPreferredAuthentications=password,keyboard-interactive --ssh-opt=-oNumberOfPasswordPrompts=1 \
    >"$out/fuzz.log" 2>&1 || echo "fuzz exit $?" >"$out/failure"
}

case "$BUILD" in
  *.zip) BUILD_ZIP=$(cd "$(dirname "$BUILD")" && pwd)/$(basename "$BUILD") ;;
  *.app|*.app/) BUILD_ZIP="$RUN/build.zip"; ditto -c -k --keepParent "$BUILD" "$BUILD_ZIP" ;;
  *.dmg) mnt=$(mktemp -d); hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$BUILD" >/dev/null
         BUILD_ZIP="$RUN/build.zip"; ditto -c -k --keepParent "$(ls -d "$mnt"/*.app | head -1)" "$BUILD_ZIP"; hdiutil detach -quiet "$mnt" ;;
  *) echo "BUILD must be .app, .zip or .dmg" >&2; exit 2 ;;
esac
export BUILD_ZIP

IFS=, read -r -a majors <<<"$MAJORS"
for major in "${majors[@]}"; do
  out="$RUN/$major"; mkdir -p "$out"
  echo "== macOS $major (seed $SEED, $STEPS steps): waiting for the host lock" >&2
  if [[ "$LOCK" == none ]]; then cycle "$major" "$out" || true
  else
    # Hold the fleet lock only for clone..delete.
    exec 9>>"$LOCK"
    perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or die; flock($f, LOCK_EX) or die "flock: $!"'
    cycle "$major" "$out" || true
    exec 9>&-
  fi
done

python3 -I - "$RUN" "$MAJORS" <<'PY'
import json, os, sys
run, majors = sys.argv[1], sys.argv[2].split(",")
rows, bad = {}, False
for m in majors:
    d = os.path.join(run, m)
    s = json.load(open(os.path.join(d, "summary.json"))) if os.path.exists(os.path.join(d, "summary.json")) else {}
    fail = open(os.path.join(d, "failure")).read().strip() if os.path.exists(os.path.join(d, "failure")) else ""
    rows[m] = {**s, "failure": fail}
    bad |= bool(fail) or s.get("crashes", 0) > 0 or s.get("hangs", 0) > 0 or s.get("relaunches", 0) > 0
    print("%-4s %-8s steps=%-5s crashes=%-3s hangs=%-3s dead=%-3s faults=%-4s %s" % (
        m, s.get("os", "?"), s.get("steps", 0), s.get("crashes", 0), s.get("hangs", 0), s.get("relaunches", 0), s.get("faults", 0), fail))
json.dump(rows, open(os.path.join(run, "matrix.json"), "w"), indent=2)
print("artifacts:", run)
sys.exit(1 if bad else 0)
PY
