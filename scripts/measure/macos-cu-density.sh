#!/usr/bin/env bash
# Dense computer-use desktops on one Mac (cmuxterm-hq#8741; leo-workspace
# research/computer-use-density-macos-2026-11-12.md). Two shapes, measured in one run:
#
#  1. Many agents in ONE macOS GUI session. Each agent is its own instance of a tiny AppKit app
#     (macos-cu-density/cud.m: a button whose click changes the window title), started like
#     `open -n`. For N agents (ns=1,4,8,16,32, stopping where it breaks) it measures virtual
#     displays (CGVirtualDisplay until one fails, and one big display holding all N windows),
#     ScreenCaptureKit per-window capture, input without focus (AXPress, AX set value,
#     CGEventPostToPid plain and with Cua Driver's field stamps) against a frontmost witness app,
#     App Nap and `taskpolicy -b`, SIGSTOP plus memory pressure (what the compressor takes from a
#     stopped app), and resume to an acted click with agents about 10% awake.
#     This runs inside a throwaway macOS 26 guest (the cu-driver-bench image, SIP off), the one
#     place a fleet step's own executables can hold Screen Recording and Accessibility (tcc-grant.sh);
#     no fleet worker's step does. The guest's console session is the "one macOS GUI session".
#     CGVirtualDisplay is also tried on the worker itself, which needs no grant.
#  2. One Virtualization.framework guest per slot (macos-cu-density/cudvz.m): three APFS clones of
#     the image, boot to sshd, host RAM per VM, saveMachineStateTo / restoreMachineStateFrom times,
#     and whether a saved VM still holds one of the two macOS VM slots. Never more than two macOS
#     VMs run at once (macOS licence 2B(iii)); the guest of shape 1 starts after these stop.
#
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/macos-cu-density.sh --ref SHA --artifact artifacts/macos-cu-density.tgz \
#     [--target-worker W] [--arg=ns=1,4,8,16,32] [--arg=ballast=64] [--arg=loop_s=60] [--arg=vz=1] \
#     [--arg=vz_mem=4096] [--arg=guest_mem=12] [--arg=guest_cpu=6] --timeout 7200
#
# Lume, the image and its cache are cu-driver-bench.sh's (cu-driver-eval/pins.json, the same lume
# home), so a worker that ran the bench does not pull the 23 GB image again. Output: CUD lines, and
# artifacts/macos-cu-density.tgz with host.json, vz.jsonl, guest/results.jsonl and summary.md.
# Exit 0 when the guest's results came back, else 4.
#
# The same cud binary is a small driver API for a prototype (one slot = one agent app):
#   cud slot lease ID | act PID [ROUTE] | shot PID OUT.png | suspend PID [bg] | resume PID [bg] |
#   mem PID | slot release PID   (the header of macos-cu-density/cud.m).
set -uo pipefail
ns=1,4,8,16,32 ballast=64 loop_s=60 vz=1 vz_mem=4096 guest_mem=12 guest_cpu=6
for arg in "$@"; do
  case "$arg" in
    ns=*) ns="${arg#ns=}" ;;
    ballast=*) ballast="${arg#ballast=}" ;;
    loop_s=*) loop_s="${arg#loop_s=}" ;;
    vz=*) vz="${arg#vz=}" ;;
    vz_mem=*) vz_mem="${arg#vz_mem=}" ;;
    guest_mem=*) guest_mem="${arg#guest_mem=}" ;;
    guest_cpu=*) guest_cpu="${arg#guest_cpu=}" ;;
    *) echo "macos-cu-density.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$ns" =~ ^[0-9]{1,3}(,[0-9]{1,3})*$ ]] || { echo "macos-cu-density.sh: ns= is a comma list of agent counts" >&2; exit 2; }
[[ "$ballast" =~ ^[0-9]{1,4}$ && "$loop_s" =~ ^[0-9]{1,4}$ && "$vz" =~ ^[01]$ ]] || { echo "macos-cu-density.sh: ballast= MB, loop_s= s, vz= 0|1" >&2; exit 2; }
[[ "$vz_mem" =~ ^[0-9]{4,5}$ && "$guest_mem" =~ ^[0-9]{1,2}$ && "$guest_cpu" =~ ^[0-9]{1,2}$ ]] || { echo "macos-cu-density.sh: vz_mem= MB, guest_mem= GB, guest_cpu= count" >&2; exit 2; }
started_at=$(date +%s)
root="$(git rev-parse --show-toplevel)"
cd "$root"
here="$root/scripts/measure/macos-cu-density"
ev="$root/scripts/measure/cu-driver-eval"
out="$root/artifacts/macos-cu-density"
rm -rf "$out" "$root/artifacts/macos-cu-density.tgz"
mkdir -p "$out/build" "$out/guest"
note() { echo "CUD $(date -u +%H:%M:%S) $*"; }
finish() {
  [[ -n "${1:-}" ]] && { note "blocked: $1"; printf '%s\n' "$1" >"$out/blocked.txt"; }
  python3 -I "$here/summarise.py" "$out" >"$out/summary.md" 2>"$out/summarise.err" || true
  cat "$out/summary.md" 2>/dev/null
  tar -czf "$root/artifacts/macos-cu-density.tgz" -C "$root/artifacts" macos-cu-density
}
if [[ -n "${CU_DRIVER_BENCH_HOME:-}" ]]; then
  lume_home="$CU_DRIVER_BENCH_HOME"
elif [[ -d /Volumes/ephemeral0/cmux-agent-work && -w /Volumes/ephemeral0/cmux-agent-work ]]; then
  lume_home=/Volumes/ephemeral0/cmux-agent-work/cu-driver-bench
else
  lume_home=/Users/Shared/cu-driver-bench
fi
mkdir -p "$lume_home/bin" "$lume_home/tmp" "$lume_home/.config"
pin() { python3 -I -c 'import functools, json, sys; print(functools.reduce(lambda d, k: d[k], sys.argv[2:], json.load(open(sys.argv[1]))))' "$ev/pins.json" "$@"; }

note "STAGE build"
b="$out/build"
app="$b/CudAgent.app"
mkdir -p "$app/Contents/MacOS"
cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.manaflow.cud-agent</string>
<key>CFBundleExecutable</key><string>cud</string>
<key>CFBundleName</key><string>CudAgent</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
cat >"$b/vz.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
EOF
cflags=(-fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -Wno-deprecated-declarations)
xcrun clang "${cflags[@]}" -o "$b/cud" "$here/cud.m" -framework AppKit -framework ApplicationServices \
  -framework ScreenCaptureKit -framework CoreGraphics >"$b/cud.log" 2>&1 || { cat "$b/cud.log"; finish "cud.m did not compile (build/cud.log)"; exit 4; }
xcrun clang "${cflags[@]}" -o "$b/cudvz" "$here/cudvz.m" -framework Foundation -framework Virtualization >"$b/cudvz.log" 2>&1 ||
  { cat "$b/cudvz.log"; finish "cudvz.m did not compile (build/cudvz.log)"; exit 4; }
cp "$b/cud" "$app/Contents/MacOS/cud"
codesign -s - -f "$app" >/dev/null 2>&1 && codesign -s - -f "$b/cud" >/dev/null 2>&1 &&
  codesign -s - -f --entitlements "$b/vz.entitlements" "$b/cudvz" >/dev/null 2>&1 || { finish "ad-hoc signing failed"; exit 4; }
note "built cud, CudAgent.app and cudvz"

note "STAGE host"
{
  echo "{"
  printf '"host": "%s", ' "$(scutil --get ComputerName 2>/dev/null || hostname)"
  printf '"model": "%s", ' "$(sysctl -n hw.model 2>/dev/null)"
  printf '"cpu": "%s", ' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  printf '"ncpu": %s, "memsize_gb": %s, ' "$(sysctl -n hw.ncpu)" "$(( $(sysctl -n hw.memsize) >> 30 ))"
  printf '"macos": "%s (%s)", ' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf '"console_user": "%s", "step_user": "%s", ' "$(stat -f %Su /dev/console)" "$(id -un)"
  printf '"compressor_mode": "%s", ' "$(sysctl -n vm.compressor_mode 2>/dev/null)"
  printf '"swapusage": "%s", ' "$(sysctl -n vm.swapusage 2>/dev/null)"
  printf '"hv_max_address_spaces": "%s", ' "$(sysctl -n kern.hv.max_address_spaces 2>/dev/null)"
  printf '"freeze_sysctl": "%s", ' "$(sysctl -n vm.freeze_enabled 2>&1 | head -1)"
  printf '"rev": "%s"' "$(git rev-parse HEAD)"
  echo "}"
} >"$out/host.json"
cat "$out/host.json"
perl -e 'alarm 30; exec @ARGV' "$b/cud" grants >"$out/host-grants.json" 2>&1 || true
perl -e 'alarm 180; exec @ARGV' "$b/cud" vdisplay 64 1280 800 >"$out/host-vdisplay.json" 2>"$out/host-vdisplay.err" || true
note "host grants $(cat "$out/host-grants.json"); host virtual displays $(head -c 600 "$out/host-vdisplay.json")"

note "STAGE lume"
lume_sum=$(pin lume sha256)
lume_tgz="$lume_home/bin/$lume_sum.tar.gz"
[[ -s "$lume_tgz" ]] || { curl -fsSL --retry 3 -o "$lume_tgz.part" "$(pin lume url)" && mv "$lume_tgz.part" "$lume_tgz"; }
[[ "$(shasum -a 256 "$lume_tgz" 2>/dev/null | awk '{print $1}')" == "$lume_sum" ]] || { rm -f "$lume_tgz"; finish "could not fetch the pinned Lume"; exit 4; }
lume_dir="$lume_home/bin/$lume_sum"
[[ -x "$lume_dir/lume" ]] || { mkdir -p "$lume_dir" && tar -xzf "$lume_tgz" -C "$lume_dir"; }
[[ -x "$lume_dir/lume" ]] || { finish "could not unpack the pinned Lume"; exit 4; }
lume_env=(env HOME="$lume_home" CFFIXED_USER_HOME="$lume_home" XDG_CONFIG_HOME="$lume_home/.config" TMPDIR="$lume_home/tmp/"
  LUME_TELEMETRY_ENABLED=0 LUME_LOG_LEVEL=error "$lume_dir/lume")
lume() { "${lume_env[@]}" "$@"; }

note "STAGE image"
image_name=$(pin image name) image_tag=$(pin image tag) image_digest=$(pin image digest)
base="cu-bench-base-${image_tag//./-}"
base_status=$(lume get "$base" -f json 2>/dev/null | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = None
r = d[0] if isinstance(d, list) and d else d
print(r.get("status", "") if isinstance(r, dict) else "")' 2>/dev/null)
base_ok() { [[ "$(lume get "$base" -f json 2>/dev/null | python3 -I -c 'import json, sys
d = json.load(sys.stdin); r = d[0] if isinstance(d, list) and d else d
print(r.get("status", "") if isinstance(r, dict) else "")' 2>/dev/null)" == stopped && "$(cat "$lume_home/$base.digest" 2>/dev/null)" == "$image_digest" ]]; }
if ! base_ok; then
  # cu-driver-bench.sh pulls the base and checks it against the digest pin; its probe suite does only that
  # (and one short boot of its own clone).
  note "no checked base $base here (status '${base_status:-none}'): cu-driver-bench.sh suite=probe pulls it"
  bash "$root/scripts/measure/cu-driver-bench.sh" suite=probe >"$out/bench-probe.log" 2>&1
  note "cu-driver-bench.sh suite=probe exit $?"
fi
if ! base_ok; then
  tail -20 "$out/bench-probe.log" 2>/dev/null
  finish "no checked base image $base on this worker (status '${base_status:-none}'): run cu-driver-bench.sh suite=probe here first"
  exit 4
fi
note "base $base ($image_name:$image_tag $image_digest)"

mine=()  # every clone this run makes, deleted at exit
cleanup() {
  [[ -n "${vz_pid:-}" ]] && kill "$vz_pid" 2>/dev/null
  [[ -n "${run_pid:-}" ]] && { kill "$run_pid" 2>/dev/null; wait "$run_pid" 2>/dev/null; }
  for vm in ${mine[@]+"${mine[@]}"}; do
    lume stop "$vm" >/dev/null 2>&1 || true
    lume delete "$vm" --force >/dev/null 2>&1 || true
  done
  [[ -n "${keydir:-}" ]] && rm -rf "$keydir"
}
trap cleanup EXIT
vm_dir() {  # the folder of Lume VM $1
  find "$lume_home" -maxdepth 5 -type f -name config.json -path "*/$1/config.json" 2>/dev/null | head -1 | xargs -I{} dirname {}
}
tag="cud-$(date +%s)-$$"

if [[ "$vz" == 1 ]]; then
  note "STAGE vz"
  : >"$out/vz.jsonl"
  dirs=()
  for x in a b c; do
    t0=$(python3 -c 'import time; print(time.time())')
    lume clone "$base" "$tag-$x" >"$out/clone-$x.log" 2>&1 || { finish "lume clone failed (clone-$x.log)"; exit 4; }
    mine+=("$tag-$x")
    printf '{"step": "lume clone %s", "seconds": %s}\n' "$x" "$(python3 -c "import time; print(round(time.time() - $t0, 3))")" >>"$out/vz.jsonl"
    d=$(vm_dir "$tag-$x")
    [[ -n "$d" && -f "$d/disk.img" && -f "$d/nvram.bin" ]] || { ls -la "$lume_home" >&2; finish "could not find the folder of clone $tag-$x"; exit 4; }
    dirs+=("$d")
  done
  printf '{"step": "disk", "disk_img_apparent_mb": %s, "disk_img_allocated_mb": %s, "free_after_clones": "%s"}\n' \
    "$(( $(stat -f %z "${dirs[0]}/disk.img") >> 20 ))" "$(du -m "${dirs[0]}/disk.img" | awk '{print $1}')" "$(df -h "$lume_home" | tail -1 | awk '{print $4}')" >>"$out/vz.jsonl"
  perl -e 'alarm 2400; exec @ARGV' "$b/cudvz" cycle "$vz_mem" 4 "$lume_home/tmp/$tag-state" "${dirs[@]}" >>"$out/vz.jsonl" 2>"$out/vz.err" &
  vz_pid=$!
  while kill -0 "$vz_pid" 2>/dev/null; do sleep 30; note "vz: $(tail -1 "$out/vz.jsonl" | cut -c1-200)"; done
  wait "$vz_pid"
  note "vz exit $?"
  vz_pid=""
  rm -rf "$lume_home/tmp/$tag-state"
  for x in a b c; do lume delete "$tag-$x" --force >/dev/null 2>&1; done
  mine=()
  cat "$out/vz.jsonl"
fi

note "STAGE guest"
vm="$tag-g"
t0=$(date +%s)
lume clone "$base" "$vm" >"$out/clone-g.log" 2>&1 || { finish "lume clone failed (clone-g.log)"; exit 4; }
mine+=("$vm")
lume set "$vm" --cpu "$guest_cpu" --memory "${guest_mem}GB" --display 1920x1080 >"$out/set.log" 2>&1 || { finish "lume set failed (set.log)"; exit 4; }
( exec "${lume_env[@]}" run "$vm" --no-display ) >"$out/run.log" 2>&1 &
run_pid=$!
booted=0
for _ in $(seq 1 90); do
  kill -0 "$run_pid" 2>/dev/null || break
  lume ssh "$vm" -t 10 true >/dev/null 2>&1 && { booted=1; break; }
  sleep 5
done
[[ $booted == 1 ]] || { tail -20 "$out/run.log"; finish "the guest's SSH never answered (run.log)"; exit 4; }
note "guest $vm answered lume ssh $(( $(date +%s) - t0 )) s after clone"
keydir="$lume_home/tmp/key-$vm"
mkdir -p "$keydir" && chmod 700 "$keydir"
ssh-keygen -q -t ed25519 -N "" -C "$vm" -f "$keydir/id" || { finish "ssh-keygen failed"; exit 4; }
ip=$(lume get "$vm" -f json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
r = d[0] if isinstance(d, list) else d
print(r.get("ipAddress") or "")' 2>/dev/null)
[[ "$ip" =~ ^[0-9.]+$ ]] || { finish "lume reported no guest IP"; exit 4; }
pubkey=$(cat "$keydir/id.pub")
setup="mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubkey' >>~/.ssh/authorized_keys"
setup+=" && echo lume | sudo -S sh -c 'echo \"lume ALL=(ALL) NOPASSWD: ALL\" >/etc/sudoers.d/cud && chmod 440 /etc/sudoers.d/cud'"
lume ssh "$vm" -t 60 "$setup" >"$out/key.log" 2>&1 || { finish "could not install the run's key in the guest (key.log)"; exit 4; }
ssh_opts=(-i "$keydir/id" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
guest() { ssh "${ssh_opts[@]}" "lume@$ip" "$@"; }
guest_n() { ssh -n "${ssh_opts[@]}" "lume@$ip" "$@"; }
guest_n true || { finish "ssh with the run's key failed"; exit 4; }
# The image's user is lume, so the guest's tree is /Users/lume/cud.
printf '#!/bin/bash\ncd /Users/lume/cud\n./cud bench /Users/lume/cud/out %q %q %q >bench.log 2>&1\necho $? >bench.status\n' \
  "$ns" "$ballast" "$loop_s" >"$b/run.sh"
cat >"$b/agent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>ai.manaflow.cud</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/Users/lume/cud/run.sh</string></array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
tar -c -C "$b" cud CudAgent.app run.sh agent.plist -C "$ev" tcc-grant.sh | guest 'rm -rf ~/cud && mkdir -p ~/cud && tar -x -C ~/cud' ||
  { finish "could not copy the probe into the guest"; exit 4; }
# The bench's own executables and bash (the LaunchAgent's process, which TCC asks about) get
# Screen Recording, Accessibility and event posting, in this throwaway SIP-off clone only.
guest_n 'bash ~/cud/tcc-grant.sh /bin/bash ~/cud/cud ~/cud/CudAgent.app/Contents/MacOS/cud' >"$out/grant.log" 2>&1 ||
  { cat "$out/grant.log"; finish "tcc-grant.sh failed in the guest (grant.log)"; exit 4; }
# As guest-start.sh: wait for the login session (its Dock), then bootstrap into gui/UID as root.
started=0
for _ in $(seq 1 30); do
  guest_n 'uid=$(id -u); pgrep -u $uid -x Dock >/dev/null && { sudo -n launchctl bootstrap gui/$uid ~/cud/agent.plist 2>/dev/null ||
    sudo -n launchctl asuser $uid launchctl bootstrap gui/$uid ~/cud/agent.plist 2>/dev/null ||
    sudo -n launchctl print gui/$uid/ai.manaflow.cud >/dev/null 2>&1; }' && { started=1; break; }
  sleep 5
done
[[ $started == 1 ]] || { finish "could not start the bench in the guest's login session"; exit 4; }
note "the bench is running in the guest's session (ns=$ns ballast=$ballast MB loop_s=$loop_s)"
deadline=$(( started_at + 6900 ))
finished=0
next=$(( $(date +%s) + 240 ))
while (( $(date +%s) < deadline )); do
  guest_n 'test -f ~/cud/bench.status' 2>/dev/null && { finished=1; break; }
  if (( $(date +%s) >= next )); then
    next=$(( $(date +%s) + 240 ))
    note "guest: $(guest_n 'tail -1 ~/cud/out/results.jsonl 2>/dev/null | cut -c1-220' 2>/dev/null)"
  fi
  sleep 10
done
guest_n 'cat ~/cud/out/results.jsonl' >"$out/guest/results.jsonl" 2>/dev/null
guest_n 'cat ~/cud/bench.log' >"$out/guest/bench.log" 2>/dev/null
guest_n 'sysctl -n hw.ncpu hw.memsize; sw_vers -productVersion; vm_stat' >"$out/guest/facts.txt" 2>/dev/null
[[ $finished == 1 ]] || { finish "the bench did not finish in the guest in the time left"; exit 4; }
note "bench exit $(guest_n 'cat ~/cud/bench.status' 2>/dev/null)"
finish
[[ -s "$out/guest/results.jsonl" ]] || exit 4
exit 0
