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
#     The jobs stage (cud jobs; cmuxterm-hq docs/research/gui-ci-partitioning/virtual-display.md)
#     runs N concurrent GUI test jobs (jobs_ns=1,2,4,8,16) for jobs_s seconds each, every job its own
#     app on its own CGVirtualDisplay (mode display) or its own window on one big virtual display
#     (mode window), driven at once through AX, key and stamped-click events to its pid, and
#     ScreenCaptureKit captures, with raw pixel clicks serialised on one console-input token; it
#     checks that no job's clicks, keys or field values reach another job's app and that no capture
#     holds another job's pixels. It runs in the guest, and on the worker's own console session
#     (host_jobs=1), where it reports the step's grants and skips at once without them. Every click
#     carries a tag (kCGEventSourceUserData) and each app logs the tags it received, so a click is
#     traced to where it landed; each job's colour is calibrated from its own window, and each job's
#     first and worst window capture is saved (guest/png). With sims=N (default 1), N headless iOS
#     simulators in the step's own device set (simctl --set) boot on the worker and loop screenshots and
#     app launches while the guest's jobs run (sims.jsonl); the default device set is checked untouched.
#  2. One Virtualization.framework guest per slot (macos-cu-density/cudvz.m): three APFS clones of
#     the image, boot to sshd, host RAM per VM, saveMachineStateTo / restoreMachineStateFrom times,
#     and whether a saved VM still holds one of the two macOS VM slots. Never more than two macOS
#     VMs run at once (macOS licence 2B(iii)); the guest of shape 1 starts after these stop.
#
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/macos-cu-density.sh --ref SHA --artifact artifacts/macos-cu-density.tgz \
#     [--target-worker W] [--arg=ns=1,4,8,16,32] [--arg=ballast=64] [--arg=loop_s=60] [--arg=vz=1] \
#     [--arg=vz_mem=4096] [--arg=guest_mem=12] [--arg=guest_cpu=6] [--arg=bench=1] \
#     [--arg=jobs_ns=1,2,4,8,16] [--arg=jobs_s=30] [--arg=jobs_modes=display,window] [--arg=host_jobs=1] [--arg=sims=1] --timeout 7200
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
bench=1 jobs_ns=1,2,4,8,16 jobs_s=30 jobs_modes=display,window host_jobs=1 sims=1
for arg in "$@"; do
  case "$arg" in
    ns=*) ns="${arg#ns=}" ;;
    ballast=*) ballast="${arg#ballast=}" ;;
    loop_s=*) loop_s="${arg#loop_s=}" ;;
    vz=*) vz="${arg#vz=}" ;;
    vz_mem=*) vz_mem="${arg#vz_mem=}" ;;
    guest_mem=*) guest_mem="${arg#guest_mem=}" ;;
    guest_cpu=*) guest_cpu="${arg#guest_cpu=}" ;;
    bench=*) bench="${arg#bench=}" ;;
    jobs_ns=*) jobs_ns="${arg#jobs_ns=}" ;;
    jobs_s=*) jobs_s="${arg#jobs_s=}" ;;
    jobs_modes=*) jobs_modes="${arg#jobs_modes=}" ;;
    host_jobs=*) host_jobs="${arg#host_jobs=}" ;;
    sims=*) sims="${arg#sims=}" ;;
    *) echo "macos-cu-density.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$ns" =~ ^[0-9]{1,3}(,[0-9]{1,3})*$ ]] || { echo "macos-cu-density.sh: ns= is a comma list of agent counts" >&2; exit 2; }
[[ "$ballast" =~ ^[0-9]{1,4}$ && "$loop_s" =~ ^[0-9]{1,4}$ && "$vz" =~ ^[01]$ ]] || { echo "macos-cu-density.sh: ballast= MB, loop_s= s, vz= 0|1" >&2; exit 2; }
[[ "$jobs_ns" =~ ^([0-9]{1,2}(,[0-9]{1,2})*)?$ && "$jobs_s" =~ ^[0-9]{1,4}$ && "$bench" =~ ^[01]$ && "$host_jobs" =~ ^[01]$ ]] ||
  { echo "macos-cu-density.sh: jobs_ns= a comma list (empty: no jobs stage), jobs_s= s, bench= 0|1, host_jobs= 0|1" >&2; exit 2; }
[[ "$sims" =~ ^[0-4]$ ]] || { echo "macos-cu-density.sh: sims= 0..4" >&2; exit 2; }
[[ "$jobs_modes" =~ ^(display|window)(,(display|window))?$ ]] || { echo "macos-cu-density.sh: jobs_modes= display,window" >&2; exit 2; }
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
  -framework ScreenCaptureKit -framework CoreGraphics -framework ImageIO >"$b/cud.log" 2>&1 || { cat "$b/cud.log"; finish "cud.m did not compile (build/cud.log)"; exit 4; }
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
if [[ "$host_jobs" == 1 && -n "$jobs_ns" ]]; then
  # The worker's own console session: what a job gets with the step's own grants, no VM. Without
  # Accessibility and Screen Recording there is nothing to run (cmux8s, 2026-11-17: the stage sat out
  # its whole 30-minute bound instead of skipping), so it is skipped here.
  if grep -Eq '"accessibility": ?(1|true)' "$out/host-grants.json" && grep -Eq '"screen_recording": ?(1|true)' "$out/host-grants.json"; then
    perl -e 'alarm 1800; exec @ARGV' "$b/cud" jobs "$out/host-jobs" "$jobs_ns" "$jobs_s" 0 "$jobs_modes" >"$out/host-jobs.log" 2>&1 || true
    note "host jobs: $(cut -c1-300 "$out/host-jobs/results.jsonl" 2>/dev/null | head -12)"
  else
    mkdir -p "$out/host-jobs"
    printf '{"stage": "jobs", "skipped": "the step has no Accessibility or Screen Recording grant in this session: %s"}\n' \
      "$(tr -d '\n"' <"$out/host-grants.json")" >"$out/host-jobs/results.jsonl"
    note "host jobs skipped: no grants ($(cat "$out/host-grants.json"))"
  fi
fi

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
  [[ -n "${sim_pid:-}" ]] && { touch "$sim_stop"; wait "$sim_pid" 2>/dev/null; }
  if [[ -n "${simset:-}" && -d "$simset" ]]; then
    xcrun simctl --set "$simset" shutdown all >/dev/null 2>&1 || true
    xcrun simctl --set "$simset" delete all >/dev/null 2>&1 || true
    rm -rf "$simset"
  fi
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
  perl -e 'alarm 2400; exec @ARGV' "$b/cudvz" cycle "$vz_mem" 4 "$lume_home/tmp/$tag-state" ${dirs[@]+"${dirs[@]}"} >>"$out/vz.jsonl" 2>"$out/vz.err" &
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
if [[ $booted != 1 ]]; then
  # Say why, not only that: is the VM process alive, what Lume reports for it (status, IP), how many
  # macOS VMs this host runs (two at most: another owner's VM takes a slot), and the vmnet DHCP leases.
  {
    echo "== lume run alive: $(kill -0 "$run_pid" 2>/dev/null && echo yes || echo no)"
    echo "== lume get $vm"; lume get "$vm" -f json 2>&1 | head -40
    echo "== lume ls"; lume ls 2>&1 | head -20
    echo "== Virtualization.framework VM processes on this host"
    pgrep -fl com.apple.Virtualization.VirtualMachine 2>&1 | head -10
    echo "== vmnet DHCP leases: $(grep -c ip_address= /var/db/dhcpd_leases 2>/dev/null || echo unreadable)"
    echo "== lume ssh $vm (last try)"; lume ssh "$vm" -t 10 true 2>&1 | tail -5
  } >"$out/guest-unreachable.txt" 2>&1
  tail -20 "$out/run.log"
  cat "$out/guest-unreachable.txt"
  vms=$(pgrep -f com.apple.Virtualization.VirtualMachine 2>/dev/null | wc -l | tr -d ' ')
  finish "the guest's SSH never answered: lume run $(kill -0 "$run_pid" 2>/dev/null && echo alive || echo exited), $vms VM process(es) on the host (guest-unreachable.txt, run.log)"
  exit 4
fi
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
{
  printf '#!/bin/bash\ncd /Users/lume/cud\nst=0\n'
  [[ -n "$jobs_ns" ]] && printf './cud jobs /Users/lume/cud/out %q %q 0 %q >jobs.log 2>&1 || st=$?\n' "$jobs_ns" "$jobs_s" "$jobs_modes"
  [[ "$bench" == 1 ]] && printf './cud bench /Users/lume/cud/out %q %q %q >bench.log 2>&1 || st=$?\n' "$ns" "$ballast" "$loop_s"
  printf 'echo $st >bench.status\n'
} >"$b/run.sh"
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
if [[ "$sims" -gt 0 ]]; then
  # Headless iOS simulators in this step's own device set: it never lists, boots or deletes another
  # simulator (scripts/ci/cmux-next-ios-sim.sh does the same). The default set's booted devices are
  # counted before and after, to show it was not touched.
  note "STAGE sims ($sims)"
  mkdir -p "$out/sims"
  simset="$lume_home/tmp/sims-$tag"
  mkdir -p "$simset"
  default_booted() { xcrun simctl list devices booted -j 2>/dev/null | python3 -I -c 'import json, sys; print(sum(len(v) for v in json.load(sys.stdin).get("devices", {}).values()))' 2>/dev/null; }
  echo "{\"stage\": \"sim-default-set\", \"when\": \"before\", \"booted\": \"$(default_booted)\"}" >>"$out/sims.jsonl"
  if choice=$(xcrun simctl list -j runtimes devicetypes 2>"$out/sims/list.err" | python3 -I "$root/scripts/ci/ios_sim_runtime.py" 2>"$out/sims/choice.err"); then
    read -r sim_runtime sim_type <<<"$choice"
    sim_udids=""
    for i in $(seq 1 "$sims"); do
      t0=$(python3 -c 'import time; print(time.time())')
      u=$(xcrun simctl --set "$simset" create "cud-sim-$i" "$sim_type" "$sim_runtime" 2>>"$out/sims/create.err") || { note "simctl create failed ($(tail -2 "$out/sims/create.err"))"; continue; }
      xcrun simctl --set "$simset" boot "$u" >/dev/null 2>>"$out/sims/boot.err"
      perl -e 'alarm 600; exec @ARGV' xcrun simctl --set "$simset" bootstatus "$u" -b >/dev/null 2>>"$out/sims/boot.err"; st=$?
      printf '{"stage": "sim-boot", "udid": "%s", "runtime": "%s", "device_type": "%s", "exit": %s, "boot_s": %s}\n' \
        "$u" "$sim_runtime" "$sim_type" "$st" "$(python3 -c "import time; print(round(time.time() - $t0, 2))")" >>"$out/sims.jsonl"
      [[ $st == 0 ]] && sim_udids="$sim_udids $u"
    done
    note "sims booted:${sim_udids:- none} ($sim_type on $sim_runtime)"
  else
    note "no iOS simulator runtime here: $(tail -2 "$out/sims/choice.err")"
    echo "{\"stage\": \"sim-boot\", \"skipped\": \"$(tail -1 "$out/sims/choice.err" | tr -d '"')\"}" >>"$out/sims.jsonl"
  fi
fi
# As guest-start.sh: wait for the login session (its Dock), then bootstrap into gui/UID as root.
started=0
for _ in $(seq 1 30); do
  guest_n 'uid=$(id -u); pgrep -u $uid -x Dock >/dev/null && { sudo -n launchctl bootstrap gui/$uid ~/cud/agent.plist 2>/dev/null ||
    sudo -n launchctl asuser $uid launchctl bootstrap gui/$uid ~/cud/agent.plist 2>/dev/null ||
    sudo -n launchctl print gui/$uid/ai.manaflow.cud >/dev/null 2>&1; }' && { started=1; break; }
  sleep 5
done
[[ $started == 1 ]] || { finish "could not start the bench in the guest's login session"; exit 4; }
note "the bench is running in the guest's session (jobs_ns=$jobs_ns jobs_s=$jobs_s jobs_modes=$jobs_modes; bench=$bench ns=$ns ballast=$ballast MB loop_s=$loop_s)"
if [[ -n "${sim_udids:-}" ]]; then
  # The simulators work while the guest's jobs run: a screenshot and an app launch per round each.
  sim_stop="$out/sims/stop"
  (
    round=0
    while [[ ! -e "$sim_stop" ]]; do
      round=$((round + 1))
      for u in $sim_udids; do
        t0=$(python3 -c 'import time; print(time.time())')
        perl -e 'alarm 60; exec @ARGV' xcrun simctl --set "$simset" io "$u" screenshot "$out/sims/$u-last.png" >/dev/null 2>&1; shot=$?
        t1=$(python3 -c 'import time; print(time.time())')
        perl -e 'alarm 60; exec @ARGV' xcrun simctl --set "$simset" launch "$u" com.apple.Preferences >/dev/null 2>&1; launch=$?
        t2=$(python3 -c 'import time; print(time.time())')
        xcrun simctl --set "$simset" terminate "$u" com.apple.Preferences >/dev/null 2>&1
        [[ $round == 1 ]] && cp "$out/sims/$u-last.png" "$out/sims/$u-first.png" 2>/dev/null
        printf '{"stage": "sim", "udid": "%s", "round": %s, "screenshot_exit": %s, "screenshot_s": %s, "launch_exit": %s, "launch_s": %s, "at": %s}\n' \
          "$u" "$round" "$shot" "$(python3 -c "print(round($t1 - $t0, 3))")" "$launch" "$(python3 -c "print(round($t2 - $t1, 3))")" "$t0" >>"$out/sims.jsonl"
      done
      sleep 1  # a round that fails at once does not spin
    done
  ) &
  sim_pid=$!
fi
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
guest_n 'cat ~/cud/jobs.log' >"$out/guest/jobs.log" 2>/dev/null
guest_n 'cd ~/cud/out && tar -c png 2>/dev/null' | tar -x -C "$out/guest" 2>/dev/null
if [[ -n "${sim_pid:-}" ]]; then
  touch "$sim_stop"
  wait "$sim_pid" 2>/dev/null
  sim_pid=""
  echo "{\"stage\": \"sim-default-set\", \"when\": \"after\", \"booted\": \"$(default_booted)\"}" >>"$out/sims.jsonl"
fi
guest_n 'sysctl -n hw.ncpu hw.memsize; sw_vers -productVersion; vm_stat' >"$out/guest/facts.txt" 2>/dev/null
[[ $finished == 1 ]] || { finish "the bench did not finish in the guest in the time left"; exit 4; }
note "bench exit $(guest_n 'cat ~/cud/bench.status' 2>/dev/null)"
finish
[[ -s "$out/guest/results.jsonl" ]] || exit 4
exit 0
