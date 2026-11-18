#!/usr/bin/env bash
# What computer use can still do while a Mac's screen is locked (ask-3cf710da4e; cmuxterm-hq
# docs/design/locked-screen-computer-use.md). Inside a throwaway macOS guest (the cu-driver-bench
# image, SIP off, the one place a step's own executables can hold Screen Recording and Accessibility;
# macos-cu-density.sh says why), with TextEdit open, macos-locked-screen-cu/guest.sh captures the
# window four ways and the displays through ScreenCaptureKit, types into it three ways and through
# Cua Driver 0.38.0 (the driver cmux's helper loads), and reads the document back through
# Accessibility: unlocked, on a CGVirtualDisplay, then after SACLockScreenImmediate, at once and
# late= seconds later. Locking a guest strands no fleet Mac: a locked mini needs a restart or a
# break-glass password to come back (cmuxterm-hq REPAIR.md).
#
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/macos-locked-screen-cu.sh --ref SHA \
#     --artifact artifacts/macos-locked-screen-cu.tgz [--arg=late=120] --timeout 3600
#
# Output: LSC lines, and artifacts/macos-locked-screen-cu.tgz with guest/results.jsonl, the PNGs
# and summary.txt. Exit 0 when the guest's results came back, else 4.
set -uo pipefail
late=120 guest_mem=8 guest_cpu=4
for arg in "$@"; do
  case "$arg" in
    late=*) late="${arg#late=}" ;;
    guest_mem=*) guest_mem="${arg#guest_mem=}" ;;
    guest_cpu=*) guest_cpu="${arg#guest_cpu=}" ;;
    *) echo "macos-locked-screen-cu.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$late" =~ ^[0-9]{1,4}$ && "$late" -le 2400 && "$guest_mem" =~ ^[0-9]{1,2}$ && "$guest_cpu" =~ ^[0-9]{1,2}$ ]] ||
  { echo "macos-locked-screen-cu.sh: late= s (at most 2400), guest_mem= GB, guest_cpu= count" >&2; exit 2; }
started_at=$(date +%s)
root="$(git rev-parse --show-toplevel)"
cd "$root"
here="$root/scripts/measure/macos-locked-screen-cu"
ev="$root/scripts/measure/cu-driver-eval"
out="$root/artifacts/macos-locked-screen-cu"
rm -rf "$out" "$root/artifacts/macos-locked-screen-cu.tgz"
mkdir -p "$out/build" "$out/guest"
note() { echo "LSC $(date -u +%H:%M:%S) $*"; }
finish() {
  [[ -n "${1:-}" ]] && { note "blocked: $1"; printf '%s\n' "$1" >"$out/blocked.txt"; }
  if [[ -s "$out/guest/results.jsonl" ]]; then
    # One line per check: phase, what, ok, pixels, text read back.
    python3 -I - "$out/guest/results.jsonl" >"$out/summary.txt" 2>&1 <<'EOF'
import json, sys
for line in open(sys.argv[1]):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    s = r.get("session") or {}
    st = r.get("stats") or {}
    bits = [r.get("phase", ""), r.get("cmd", "") or "note", "locked=%s" % s.get("locked", "")]
    for k in ("ok", "is_error", "error", "note", "after", "text", "set_err", "display_id", "applied"):
        if r.get(k) not in (None, ""):
            bits.append("%s=%s" % (k, str(r[k])[:160].replace("\n", " ")))
    if st:
        bits.append("px=%sx%s lit=%.2f colors=%s" % (st.get("w"), st.get("h"), st.get("lit", 0), st.get("colors")))
    print(" | ".join(str(b) for b in bits))
EOF
    cat "$out/summary.txt"
  fi
  tar -czf "$root/artifacts/macos-locked-screen-cu.tgz" -C "$root/artifacts" macos-locked-screen-cu
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
xcrun clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -Wno-deprecated-declarations -o "$b/lockprobe" \
  "$here/lockprobe.m" -framework Foundation -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit -framework CoreGraphics \
  -framework IOKit >"$b/lockprobe.log" 2>&1 || { cat "$b/lockprobe.log"; finish "lockprobe.m did not compile (build/lockprobe.log)"; exit 4; }
codesign -s - -f "$b/lockprobe" >/dev/null 2>&1 || { finish "ad-hoc signing failed"; exit 4; }
cp "$here/guest.sh" "$b/guest.sh"
printf '%s\n' "$late" >"$b/late"
drv_sum=$(pin drivers cua-driver-0.38.0 sha256)
drv_tgz="$lume_home/bin/$drv_sum.tar.gz"
[[ -s "$drv_tgz" ]] || { curl -fsSL --retry 3 -o "$drv_tgz.part" "$(pin drivers cua-driver-0.38.0 url)" && mv "$drv_tgz.part" "$drv_tgz"; }
[[ "$(shasum -a 256 "$drv_tgz" 2>/dev/null | awk '{print $1}')" == "$drv_sum" ]] || { rm -f "$drv_tgz"; finish "could not fetch the pinned Cua Driver"; exit 4; }
mkdir -p "$b/drv" && tar -xzf "$drv_tgz" -C "$b/drv" && cp "$b/drv/$(pin drivers cua-driver-0.38.0 binary)" "$b/cua-driver" ||
  { finish "could not unpack the pinned Cua Driver"; exit 4; }
note "built lockprobe; Cua Driver 0.38.0 ($drv_sum)"

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

vm="lsc-$(date +%s)-$$"
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
setup+=" && echo lume | sudo -S sh -c 'echo \"lume ALL=(ALL) NOPASSWD: ALL\" >/etc/sudoers.d/lsc && chmod 440 /etc/sudoers.d/lsc'"
lume ssh "$vm" -t 60 "$setup" >"$out/key.log" 2>&1 || { finish "could not install the run's key in the guest (key.log)"; exit 4; }
ssh_opts=(-i "$keydir/id" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
guest() { ssh "${ssh_opts[@]}" "lume@$ip" "$@"; }
guest_n() { ssh -n "${ssh_opts[@]}" "lume@$ip" "$@"; }
guest_n true || { finish "ssh with the run's key failed"; exit 4; }
cat >"$b/agent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>ai.manaflow.lsc</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/Users/lume/lsc/guest.sh</string></array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
tar -c -C "$b" lockprobe cua-driver guest.sh late agent.plist -C "$ev" tcc-grant.sh | guest 'rm -rf ~/lsc && mkdir -p ~/lsc && tar -x -C ~/lsc' ||
  { finish "could not copy the probe into the guest"; exit 4; }
# bash (the LaunchAgent's process, which TCC asks about), the probe and the driver get Screen
# Recording, Accessibility and event posting, in this throwaway SIP-off clone only.
guest_n 'bash ~/lsc/tcc-grant.sh /bin/bash ~/lsc/lockprobe ~/lsc/cua-driver' >"$out/grant.log" 2>&1 ||
  { cat "$out/grant.log"; finish "tcc-grant.sh failed in the guest (grant.log)"; exit 4; }
guest_n 'sw_vers; csrutil status; pmset -g | grep -E "displaysleep|sleep"; defaults read com.apple.screensaver 2>&1 | head -5' >"$out/guest/facts.txt" 2>&1
started=0
for _ in $(seq 1 30); do
  guest_n 'uid=$(id -u); pgrep -u $uid -x Dock >/dev/null && { sudo -n launchctl bootstrap gui/$uid ~/lsc/agent.plist 2>/dev/null ||
    sudo -n launchctl asuser $uid launchctl bootstrap gui/$uid ~/lsc/agent.plist 2>/dev/null ||
    sudo -n launchctl print gui/$uid/ai.manaflow.lsc >/dev/null 2>&1; }' && { started=1; break; }
  sleep 5
done
[[ $started == 1 ]] || { finish "could not start guest.sh in the guest's login session"; exit 4; }
note "guest.sh is running in the guest's session (late=$late)"
deadline=$(( started_at + 3300 ))
finished=0
while (( $(date +%s) < deadline )); do
  guest_n 'test -f ~/lsc/status' 2>/dev/null && { finished=1; break; }
  sleep 10
done
guest_n 'cd ~/lsc/out && tar -c .' | tar -x -C "$out/guest" 2>/dev/null
guest_n 'ioreg -n Root -d1 | grep -E "IOConsoleLocked|CGSSessionScreenIsLocked"' >"$out/guest/ioreg-after.txt" 2>&1
[[ $finished == 1 ]] || { finish "guest.sh did not finish in the time left"; exit 4; }
finish
[[ -s "$out/guest/results.jsonl" ]] || exit 4
exit 0
