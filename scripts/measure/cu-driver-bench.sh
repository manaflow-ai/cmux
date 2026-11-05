#!/usr/bin/env bash
# Cua Driver Bench v2 in a macOS 26 VM (HQ#7146 G3a; scripts/measure/cu-driver-eval/README.md,
# "Bench"). This first stage brings the VM up and reports what the guest has. It takes the pinned
# Lume and the pinned trycua/macos-tahoe-cua image (macOS 26.5.2 with SIP off, the image Cua's
# registered runs used), clones it for this run (an APFS clone: the base image is never changed),
# sets 6 CPUs, 12 GB and a 1920x1080 display, boots it headless, and over SSH records the guest's
# macOS, display, SIP, Xcode tools, Homebrew, Python, Node, git, and whether it reaches the model route.
# Then it stops and deletes the clone. The bench run itself comes in the next stage. Run it alone on a
# macOS 26 worker with room for the image (about 23 GB to pull, 160 GB sparse on disk):
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/cu-driver-bench.sh --ref SHA --artifact artifacts/cu-driver-bench.tgz \
#     [--target-worker aws-m4pro-8] [--arg=base_url=http://HOST:PORT] --timeout 7200
# base_url= is the team subrouter's Claude route (as scripts/measure/team-eval.sh takes it); the
# guest only checks that it answers. Output: CU-DRIVER-BENCH lines and artifacts/cu-driver-bench.tgz
# (cu-driver-bench/vm.json and the Lume logs). Exit 0 when vm.json was written, else 4.
set -uo pipefail
base_url=""
for arg in "$@"; do
  case "$arg" in
    base_url=*) base_url="${arg#base_url=}" ;;
    *) echo "cu-driver-bench.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$base_url" || "$base_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "cu-driver-bench.sh: base_url=http://HOST[:PORT]" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
here="$root/scripts/measure/cu-driver-eval"
out="$root/artifacts/cu-driver-bench"
rm -rf "$out" "$root/artifacts/cu-driver-bench.tgz"
mkdir -p "$out"
# Lume's own home (its image cache and VMs) persists across runs on this worker, so the image is
# pulled once; only this run's clone is made and deleted. A step has its own HOME, so the cache lives
# on the AWS minis' work volume, else in /Users/Shared.
if [[ -n "${CU_DRIVER_BENCH_HOME:-}" ]]; then
  lume_home="$CU_DRIVER_BENCH_HOME"
elif [[ -d /Volumes/ephemeral0/cmux-agent-work && -w /Volumes/ephemeral0/cmux-agent-work ]]; then
  lume_home=/Volumes/ephemeral0/cmux-agent-work/cu-driver-bench
else
  lume_home=/Users/Shared/cu-driver-bench
fi
mkdir -p "$lume_home/bin" "$lume_home/tmp" "$lume_home/.config"
pin() { python3 -I -c 'import functools, json, sys; print(functools.reduce(lambda d, k: d[k], sys.argv[2:], json.load(open(sys.argv[1]))))' "$here/pins.json" "$@"; }
facts="{}"
note() { echo "CU-DRIVER-BENCH $*"; }
finish() {
  python3 -I - "$out/vm.json" "$facts" "${1:-}" <<'EOF'
import json, sys
facts = json.loads(sys.argv[2])
if sys.argv[3]:
    facts["blocked"] = sys.argv[3]
open(sys.argv[1], "w").write(json.dumps(facts, indent=2, sort_keys=True) + "\n")
EOF
  cat "$out/vm.json"
  tar -czf "$root/artifacts/cu-driver-bench.tgz" -C "$root/artifacts" cu-driver-bench
}

note "STAGE lume"
lume_sum=$(pin lume sha256)
lume_tgz="$lume_home/bin/$lume_sum.tar.gz"
if [[ ! -s "$lume_tgz" ]]; then
  curl -fsSL --retry 3 -o "$lume_tgz.part" "$(pin lume url)" && mv "$lume_tgz.part" "$lume_tgz"
fi
if [[ "$(shasum -a 256 "$lume_tgz" 2>/dev/null | awk '{print $1}')" != "$lume_sum" ]]; then
  rm -f "$lume_tgz"
  finish "could not fetch the pinned Lume"
  exit 4
fi
lume_dir="$lume_home/bin/$lume_sum"
[[ -x "$lume_dir/lume" ]] || { mkdir -p "$lume_dir" && tar -xzf "$lume_tgz" -C "$lume_dir"; }
[[ -x "$lume_dir/lume" ]] || { rm -rf "$lume_dir"; finish "could not unpack the pinned Lume"; exit 4; }
# Foundation takes the home directory from CFFIXED_USER_HOME, not HOME, and Lume assembles a pull in
# TMPDIR: all three point into the cache, so the image, the clones and the pull's scratch live there.
lume_env=(env HOME="$lume_home" CFFIXED_USER_HOME="$lume_home" XDG_CONFIG_HOME="$lume_home/.config" TMPDIR="$lume_home/tmp/"
  LUME_TELEMETRY_ENABLED=0 LUME_LOG_LEVEL=error "$lume_dir/lume")
lume() { "${lume_env[@]}" "$@"; }
note "lume home $lume_home"

note "STAGE image"
image_name=$(pin image name)
image_tag=$(pin image tag)
image_digest=$(pin image digest)
base="cu-bench-base-${image_tag//./-}"
# The tag must still name the pinned digest; a moved tag is refused, never pulled.
token=$(curl -fsSL "https://ghcr.io/token?scope=repository:$image_name:pull" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["token"])') ||
  { finish "could not get a ghcr.io pull token for $image_name"; exit 4; }
accept="application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json"
accept+=",application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json"
live=$(curl -fsSI -H "Authorization: Bearer $token" -H "Accept: $accept" \
  "https://ghcr.io/v2/$image_name/manifests/$image_tag" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')
if [[ "$live" != "$image_digest" ]]; then
  finish "ghcr.io/$image_name:$image_tag is ${live:-unreadable}, not the pinned $image_digest"
  exit 4
fi
# A pull that was cut short leaves a base Lume still calls provisioning: delete it and pull again.
base_status=$(lume get "$base" -f json 2>/dev/null | python3 -I -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    data = None
row = data[0] if isinstance(data, list) and data else data
print(row.get("status", "") if isinstance(row, dict) else "")' 2>/dev/null)
# A base counts only with the digest file this script writes after checking what Lume pulled.
base_digest_file="$lume_home/$base.digest"
if [[ -n "$base_status" && ( "$base_status" != stopped || "$(cat "$base_digest_file" 2>/dev/null)" != "$image_digest" ) ]]; then
  note "base $base is $base_status without a checked $image_digest; pulling it again"
  lume delete "$base" --force >/dev/null 2>&1 || true
  base_status=""
fi
if [[ -z "$base_status" ]]; then
  rm -f "$base_digest_file"
  rm -rf "$lume_home/tmp/"* # a cut-short pull's scratch; this folder is only this script's
  started=$(date +%s)
  # Lume pulls by tag only, and the tag can move after the check above. With --verbose it logs the
  # Docker-Content-Digest of the manifest it fetched (manifest_id=sha256_HEX, Lume 0.6.1) and checks
  # each layer against that manifest, so the logged digest is what the base holds.
  lume pull --verbose "${image_name#*/}:$image_tag" "$base" --organization "${image_name%%/*}" >"$out/pull.log" 2>&1 ||
    { tail -20 "$out/pull.log"; finish "lume pull failed (pull.log)"; exit 4; }
  pulled=$(sed -n 's/.*DEBUG: Pulling image .*manifest_id=\(sha256_[0-9a-f]*\).*/\1/p' "$out/pull.log" | head -1)
  if [[ "${pulled/sha256_/sha256:}" != "$image_digest" ]]; then
    lume delete "$base" --force >/dev/null 2>&1 || true
    finish "lume pulled ${pulled:-an unlogged manifest}, not the pinned $image_digest; the base was deleted"
    exit 4
  fi
  echo "$image_digest" >"$base_digest_file"
  note "pulled $image_digest in $(( $(date +%s) - started )) s"
fi

note "STAGE boot"
# A clone an earlier run could not delete (its step was killed) is removed first.
if [[ -s "$lume_home/leftover" ]]; then
  still=()
  while read -r old; do
    [[ "$old" == cu-bench-* ]] || continue
    lume stop "$old" >/dev/null 2>&1 || true
    lume delete "$old" --force >/dev/null 2>&1 || still+=("$old")
  done <"$lume_home/leftover"
  printf '%s\n' ${still[@]+"${still[@]}"} >"$lume_home/leftover"
fi
vm="cu-bench-$(date +%s)-$$"
echo "$vm" >>"$lume_home/leftover"
run_pid=""
cleanup() {
  lume stop "$vm" >/dev/null 2>&1 || true
  if [[ -n "$run_pid" ]]; then
    kill "$run_pid" 2>/dev/null || true
    wait "$run_pid" 2>/dev/null || true
  fi
  lume delete "$vm" --force >/dev/null 2>&1 && grep -v -x "$vm" "$lume_home/leftover" >"$lume_home/leftover.new" 2>/dev/null
  [[ -f "$lume_home/leftover.new" ]] && mv "$lume_home/leftover.new" "$lume_home/leftover"
}
trap cleanup EXIT
lume clone "$base" "$vm" >"$out/clone.log" 2>&1 || { finish "lume clone failed (clone.log)"; exit 4; }
lume set "$vm" --cpu 6 --memory 12GB --display 1920x1080 >"$out/set.log" 2>&1 || { finish "lume set failed (set.log)"; exit 4; }
# exec, so $! is Lume's own process, not a subshell around it.
( exec "${lume_env[@]}" run "$vm" --no-display ) >"$out/run.log" 2>&1 &
run_pid=$!
booted=0
for _ in $(seq 1 90); do
  kill -0 "$run_pid" 2>/dev/null || break
  if lume ssh "$vm" -t 10 true >/dev/null 2>&1; then booted=1; break; fi
  sleep 5 # bounded wait for the guest's SSH (7.5 min)
done
[[ $booted == 1 ]] || { tail -20 "$out/run.log"; finish "the guest's SSH never answered (run.log)"; exit 4; }

note "STAGE guest"
probe='
printf "macos=%s\n" "$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
printf "display=%s\n" "$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n "s/^ *Resolution: //p" | head -1)"
printf "sip=%s\n" "$(csrutil status 2>/dev/null | head -1)"
printf "xcode_tools=%s\n" "$(xcode-select -p 2>/dev/null)"
printf "swiftc=%s\n" "$(xcrun --find swiftc 2>/dev/null)"
printf "brew=%s\n" "$(command -v brew || ls /opt/homebrew/bin/brew 2>/dev/null)"
printf "python=%s\n" "$( (/opt/homebrew/bin/python3 --version || python3 --version) 2>&1 | head -1)"
printf "node=%s\n" "$( (/opt/homebrew/bin/node --version || node --version) 2>&1 | head -1)"
printf "git=%s\n" "$(git --version 2>&1 | head -1)"
printf "free=%s\n" "$(df -h / | tail -1 | awk "{print \$4}")"
printf "console_user=%s\n" "$(stat -f %Su /dev/console)"
'
[[ -n "$base_url" ]] && probe+="printf 'route=%s\n' \"\$(curl -s -m 10 -o /dev/null -w '%{http_code}' '$base_url/_subrouter/ready')\""$'\n'
lume ssh "$vm" -t 120 "$probe" >"$out/guest.txt" 2>"$out/guest.err" || note "the guest probe exited $?"
cat "$out/guest.txt"
facts=$(python3 -I - "$out/guest.txt" "$(sw_vers -productVersion)" "$(scutil --get ComputerName 2>/dev/null || hostname)" "$image_name:$image_tag" "$image_digest" "$lume_sum" "$(git rev-parse HEAD)" <<'EOF'
import json, sys
KEYS = {"macos", "display", "sip", "xcode_tools", "swiftc", "brew", "python", "node", "git", "free", "console_user", "route"}
guest = {}
for line in open(sys.argv[1]):
    key, _, value = line.rstrip("\n").partition("=")
    if key in KEYS:  # Lume's own log lines share this stream
        guest[key] = value
print(json.dumps({"schema": "cmux.cu-driver-bench.vm/1", "host": sys.argv[3], "host_macos": sys.argv[2],
                  "image": sys.argv[4], "digest": sys.argv[5], "lume_sha256": sys.argv[6], "rev": sys.argv[7],
                  "vm": {"cpu": 6, "memory_gb": 12, "display": "1920x1080"}, "guest": guest}))
EOF
)
finish
