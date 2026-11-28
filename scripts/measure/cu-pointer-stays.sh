#!/usr/bin/env bash
# Does computer use leave the person's pointer where it is? (ask-f3da540f27: "the computer use cursor
# hijacking my real cursor"). Inside a throwaway macOS guest (the cu-driver-bench image, SIP off,
# cu-driver-eval/tcc-grant.sh; macos-locked-screen-cu.sh is the same harness), the Rust Computer Use
# engine built from this ref (cmux-rd __computer-use-worker, the Screen Sharing helper's mode, on a
# Mac with no cmux Remote) drives a small AppKit target (cu-pointer-stays/cpsprobe.m): click at x/y,
# click on an element, drag, scroll and move_pointer, in delivery background and foreground, with
# computerUse.allowForeground on. Before each gesture the probe parks the real pointer
# (CGWarpMouseCursorPosition, as the person would leave it), samples it every 10 ms through the call
# (CGEventGetLocation(CGEventCreate(NULL))), and the target's own event log says whether the gesture
# landed. screencapture -v -C records the screen with the system cursor drawn.
#
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/cu-pointer-stays.sh --ref SHA \
#     --artifact artifacts/cu-pointer-stays.tgz [--arg=engine_ref=SHA] --timeout 3600
#
# engine_ref= builds the engine from another commit (base behaviour) with this ref's harness.
# Output: lines "CPS <tool> <delivery> moved_pt=<max> landed=<bool>", and
# artifacts/cu-pointer-stays.tgz with guest/results.jsonl, guest/cps.mov, a PNG per gesture,
# guest/target.log and build logs. Exit 1 when any gesture moved the pointer more than 1 pt,
# 4 when the run could not measure, else 0.
set -uo pipefail
engine_ref="" guest_mem=8 guest_cpu=4
for arg in "$@"; do
  case "$arg" in
    engine_ref=*) engine_ref="${arg#engine_ref=}" ;;
    guest_mem=*) guest_mem="${arg#guest_mem=}" ;;
    guest_cpu=*) guest_cpu="${arg#guest_cpu=}" ;;
    *) echo "cu-pointer-stays.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ ( -z "$engine_ref" || "$engine_ref" =~ ^[0-9a-f]{40}$ ) && "$guest_mem" =~ ^[0-9]{1,2}$ && "$guest_cpu" =~ ^[0-9]{1,2}$ ]] ||
  { echo "cu-pointer-stays.sh: engine_ref= a full sha, guest_mem= GB, guest_cpu= count" >&2; exit 2; }
started_at=$(date +%s)
root="$(git rev-parse --show-toplevel)"
cd "$root"
here="$root/scripts/measure/cu-pointer-stays"
ev="$root/scripts/measure/cu-driver-eval"
out="$root/artifacts/cu-pointer-stays"
rm -rf "$out" "$root/artifacts/cu-pointer-stays.tgz"
mkdir -p "$out/build" "$out/guest"
note() { echo "CPS-STAGE $(date -u +%H:%M:%S) $*"; }
finish() {
  [[ -n "${1:-}" ]] && { note "blocked: $1"; printf '%s\n' "$1" >"$out/blocked.txt"; }
  [[ -s "$out/guest/cps.txt" ]] && cat "$out/guest/cps.txt"
  tar -czf "$root/artifacts/cu-pointer-stays.tgz" -C "$root/artifacts" cu-pointer-stays
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
xcrun clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -Wno-deprecated-declarations -o "$b/cpsprobe" \
  "$here/cpsprobe.m" -framework Foundation -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  >"$b/cpsprobe.log" 2>&1 || { cat "$b/cpsprobe.log"; finish "cpsprobe.m did not compile (build/cpsprobe.log)"; exit 4; }
codesign -s - -f "$b/cpsprobe" >/dev/null 2>&1 || { finish "ad-hoc signing failed"; exit 4; }
cp "$here/guest.sh" "$here/cps.py" "$b/"

# The engine: cmux-rd (cmux-tui/crates/cmux-rd-host) with only its computer-use feature, whose
# __computer-use-worker mode is the macOS Computer Use worker NIGHTLY's daemon starts.
cargo_bin=$(command -v cargo || echo "$HOME/.cargo/bin/cargo")
[[ -x "$cargo_bin" ]] || { finish "no cargo on this worker (PATH=$PATH): the engine cannot be built here"; exit 4; }
src="$root"
if [[ -n "$engine_ref" ]]; then
  src="$lume_home/cps/tree-$engine_ref"
  if [[ ! -f "$src/.complete" ]]; then
    rm -rf "$src"
    git cat-file -e "$engine_ref^{commit}" 2>/dev/null || git fetch -q --no-tags --no-recurse-submodules origin "$engine_ref" 2>/dev/null ||
      git fetch -q --no-tags --no-recurse-submodules https://github.com/manaflow-ai/cmux.git "$engine_ref" ||
      { finish "could not fetch engine_ref $engine_ref"; exit 4; }
    mkdir -p "$src" && git archive "$engine_ref" -- cmux-tui | tar -x -C "$src" && touch "$src/.complete" ||
      { finish "could not unpack engine_ref $engine_ref"; exit 4; }
  fi
fi
engine_sha=${engine_ref:-$(git rev-parse HEAD)}
target_dir="$lume_home/cps/target"
mkdir -p "$target_dir"
build_rd() {
  (cd "$src/cmux-tui/crates/cmux-rd-host" && MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_TARGET_DIR="$target_dir" \
    "$cargo_bin" build --release --locked "$@" --bin cmux-rd </dev/null) >>"$b/engine.log" 2>&1
}
t=$(date +%s)
build_rd --no-default-features --features computer-use || { note "computer-use alone did not build; default features"; build_rd; } ||
  { tail -30 "$b/engine.log"; finish "cmux-rd did not build at ${engine_sha:0:12} (build/engine.log)"; exit 4; }
cp "$target_dir/release/cmux-rd" "$b/cmux-rd" && codesign -s - -f "$b/cmux-rd" >/dev/null 2>&1 || { finish "could not sign cmux-rd"; exit 4; }
echo "$engine_sha" >"$out/engine-sha"
note "built cpsprobe and cmux-rd at ${engine_sha:0:12} in $(( $(date +%s) - t )) s ($("$cargo_bin" --version))"

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
base_ok() { [[ "$(lume get "$base" -f json 2>/dev/null | python3 -I -c 'import json, sys
d = json.load(sys.stdin); r = d[0] if isinstance(d, list) and d else d
print(r.get("status", "") if isinstance(r, dict) else "")' 2>/dev/null)" == stopped && "$(cat "$lume_home/$base.digest" 2>/dev/null)" == "$image_digest" ]]; }
if ! base_ok; then
  note "no checked base $base here: cu-driver-bench.sh suite=probe pulls it"
  bash "$root/scripts/measure/cu-driver-bench.sh" suite=probe >"$out/bench-probe.log" 2>&1
  note "cu-driver-bench.sh suite=probe exit $?"
fi
base_ok || { tail -20 "$out/bench-probe.log" 2>/dev/null; finish "no checked base image $base on this worker"; exit 4; }
note "base $base ($image_name:$image_tag $image_digest)"

vm="cps-$(date +%s)-$$"
cleanup() {
  [[ -n "${run_pid:-}" ]] && { kill "$run_pid" 2>/dev/null; wait "$run_pid" 2>/dev/null; }
  if [[ -n "${cloned:-}" ]]; then
    lume stop "$vm" >/dev/null 2>&1 || true
    lume delete "$vm" --force >/dev/null 2>&1 || true
  fi
  [[ -n "${keydir:-}" ]] && rm -rf "$keydir"
}
trap cleanup EXIT

note "STAGE guest"
lume clone "$base" "$vm" >"$out/clone.log" 2>&1 || { finish "lume clone failed (clone.log)"; exit 4; }
cloned=1
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
setup+=" && echo lume | sudo -S sh -c 'echo \"lume ALL=(ALL) NOPASSWD: ALL\" >/etc/sudoers.d/cps && chmod 440 /etc/sudoers.d/cps'"
lume ssh "$vm" -t 60 "$setup" >"$out/key.log" 2>&1 || { finish "could not install the run's key in the guest (key.log)"; exit 4; }
ssh_opts=(-i "$keydir/id" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
guest() { ssh "${ssh_opts[@]}" "lume@$ip" "$@"; }
guest_n() { ssh -n "${ssh_opts[@]}" "lume@$ip" "$@"; }
guest_n true || { finish "ssh with the run's key failed"; exit 4; }
cat >"$b/agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>ai.manaflow.cps</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/Users/lume/cps/guest.sh</string></array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
tar -c -C "$b" cpsprobe cmux-rd guest.sh cps.py agent.plist -C "$ev" tcc-grant.sh | guest 'rm -rf ~/cps && mkdir -p ~/cps && tar -x -C ~/cps' ||
  { finish "could not copy the probe and engine into the guest"; exit 4; }
# bash (the LaunchAgent's process, which TCC asks about), the probe and the engine get Screen
# Recording, Accessibility and event posting, in this throwaway SIP-off clone only.
guest_n 'bash ~/cps/tcc-grant.sh /bin/bash ~/cps/cpsprobe ~/cps/cmux-rd' >"$out/grant.log" 2>&1 ||
  { cat "$out/grant.log"; finish "tcc-grant.sh failed in the guest (grant.log)"; exit 4; }
guest_n 'sw_vers; csrutil status; /usr/bin/python3 -V; system_profiler SPDisplaysDataType | grep -E "Resolution|Retina"' >"$out/guest/facts.txt" 2>&1
started=0
for _ in $(seq 1 30); do
  guest_n 'uid=$(id -u); pgrep -u $uid -x Dock >/dev/null && { sudo -n launchctl bootstrap gui/$uid ~/cps/agent.plist 2>/dev/null ||
    sudo -n launchctl asuser $uid launchctl bootstrap gui/$uid ~/cps/agent.plist 2>/dev/null ||
    sudo -n launchctl print gui/$uid/ai.manaflow.cps >/dev/null 2>&1; }' && { started=1; break; }
  sleep 5
done
[[ $started == 1 ]] || { finish "could not start guest.sh in the guest's login session"; exit 4; }
note "guest.sh is running in the guest's session (engine ${engine_sha:0:12})"
deadline=$(( started_at + 3300 ))
finished=0
while (( $(date +%s) < deadline )); do
  guest_n 'test -f ~/cps/status' 2>/dev/null && { finished=1; break; }
  sleep 10
done
guest_n 'cd ~/cps/out && tar -c .' | tar -x -C "$out/guest" 2>/dev/null
guest_status=$(guest_n 'cat ~/cps/status' 2>/dev/null)
[[ $finished == 1 ]] || { finish "guest.sh did not finish in the time left"; exit 4; }
[[ -s "$out/guest/cps.txt" ]] || { tail -5 "$out/guest/results.jsonl" 2>/dev/null; finish "the guest measured nothing (status ${guest_status:-none}; guest/results.jsonl)"; exit 4; }
finish
note "video: artifacts/cu-pointer-stays/guest/cps.mov ($(stat -f %z "$out/guest/cps.mov" 2>/dev/null || echo 0) bytes)"
# Over 1 pt anywhere fails the run.
awk '{ split($4, a, "="); if (a[2] + 0 > 1.0) bad = 1 } END { exit bad ? 1 : 0 }' "$out/guest/cps.txt"
