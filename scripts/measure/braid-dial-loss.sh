#!/usr/bin/env bash
# Connect time under packet loss (RFD 0127 cut 1 duress; Leo, 2026-11-25: "honestly guys these rfds need to be
# built asap ... we simply go and move."). What it measures: the hedged TCP dial every remote route takes
# (cmux-remote `provider::hedge::connect_tcp`, the Braid race in cmux-braid-path) between two network namespaces
# joined by a veth with netem delay and random loss on both sides, so SYNs and SYN-ACKs drop for real. The name
# resolves to IPv6 and IPv4, as a dual-stack host does. One dial per fresh bench process (no last-good route, an
# empty standby pool: a first attach), N dials per loss level; a dial past the bench's 10 s budget counts failed.
# before_ref=SHA builds the same bench at that commit too and runs the two arms interleaved, one harness.
#
#   scripts/measure/braid-dial-loss.sh [loss=0,2,5,10] [n=40] [delay_ms=25] [before_ref=SHA] [out=DIR]
#   cmux-ci test --timeout 2400 -- bash scripts/measure/braid-dial-loss.sh loss=0,5,10 n=40 before_ref=SHA
#   (cmux-ci needs a runner with sch_netem: from HQ, --setup netem; a lane VM with sudo runs it directly)
#
# Needs root or passwordless sudo, ip and tc: a Linux VM or CI runner, never a person's machine. It makes and
# removes only its own namespaces and veth, named for this run's pid (bdl-PID-c, bdl-PID-s, bdlPIDc/s), and
# /etc/netns/bdl-PID-c; it never touches another job's namespaces (the braid bench rigs' braid-c/braid-s).
# Rows: OUT/rows.jsonl (OUT is $FAST_CHECKS_OUT under cmux-ci, so --artifact brings them back), one per arm and
# loss level: {arm, sha, loss_pct, delay_ms, n, failed, p50_ms, p95_ms, max_ms, mean_ms}.
set -euo pipefail
trap 'echo "braid-dial-loss.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

loss="0,2,5,10" n=40 delay_ms=25 before_ref="" out="${FAST_CHECKS_OUT:-artifacts/braid-dial-loss}"
for kv in "$@"; do
  case "$kv" in
    loss=*) loss="${kv#*=}" ;;
    n=*) n="${kv#*=}" ;;
    delay_ms=*) delay_ms="${kv#*=}" ;;
    before_ref=*) before_ref="${kv#*=}" ;;
    out=*) out="${kv#*=}" ;;
    *) echo "braid-dial-loss.sh: unknown arg '$kv' (loss=, n=, delay_ms=, before_ref=, out=)" >&2; exit 2 ;;
  esac
done
[[ "$loss" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] || { echo "braid-dial-loss.sh: loss=PCT[,PCT...], each 0-99" >&2; exit 2; }
[[ "$n" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "braid-dial-loss.sh: n is 1-9999" >&2; exit 2; }
[[ "$delay_ms" =~ ^[0-9]{1,4}$ ]] || { echo "braid-dial-loss.sh: delay_ms is 0-9999" >&2; exit 2; }

if [[ $(id -u) == 0 ]]; then sudo=(); else sudo=(sudo -n); fi
"${sudo[@]}" true 2>/dev/null || { echo "braid-dial-loss.sh: needs root or passwordless sudo (netns, tc); run it on a Linux CI runner" >&2; exit 2; }
for tool in ip tc python3 cargo; do command -v "$tool" >/dev/null || { echo "braid-dial-loss.sh: $tool not found" >&2; exit 2; }; done

# netem preflight before any build: a kernel without sch_netem (the Blacksmith image) stops here, in seconds
# (handbook netem-route-without-host-module: from HQ, cmux-ci test --setup netem; or any Linux host with the module).
"${sudo[@]}" modprobe sch_netem 2>/dev/null || true
pf="bdlpf$$"
pf_ok=1
if "${sudo[@]}" ip link add "$pf" type dummy 2>/dev/null \
  && "${sudo[@]}" tc qdisc add dev "$pf" root netem delay 1ms loss 1% 2>/dev/null; then pf_ok=0; fi
"${sudo[@]}" ip link del "$pf" 2>/dev/null || true
[[ $pf_ok == 0 ]] || { echo "braid-dial-loss.sh: no netem on kernel $(uname -r); next: run on a host with sch_netem (HQ: cmux-ci test --setup netem)" >&2; exit 2; }
repo=$(git rev-parse --show-toplevel)
mkdir -p "$out"; out=$(cd "$out" && pwd); rows="$out/rows.jsonl"; : >"$rows"
command -v clang >/dev/null || { "${sudo[@]}" apt-get update -qq && "${sudo[@]}" apt-get install -y -qq clang libclang-dev pkg-config; }

# build TREE TARGET_DIR: the bench binary's path on stdout; the tree's ghostty-next pin is fetched (ghostty-vt-sys
# is in the cmux-remote graph). Any failure stops the run: a build that fails must not read as 40 failed dials.
build() {
  [[ -e "$1/ghostty-next/build.zig" ]] || git -C "$1" submodule update --init --depth 1 ghostty-next >&2 || return 1
  (cd "$1/cmux-tui" && CARGO_TARGET_DIR="$2" cargo build -q --release -p cmux-remote --example braid_dial_bench >&2) || return 1
  [[ -x "$2/release/examples/braid_dial_bench" ]] || return 1
  echo "$2/release/examples/braid_dial_bench"
}
# Zig for ghostty-vt-sys, as hook-deadline.sh gets it: the repo's pinned installer, its CMUX_ZIG exported here.
if ! command -v zig >/dev/null && [[ -z "${ZIG:-}${CMUX_ZIG:-}" ]]; then
  [[ -e "$repo/ghostty-next/build.zig.zon" ]] || git -C "$repo" submodule update --init --depth 1 ghostty-next >&2
  zig_env=$(mktemp)
  (cd "$repo" && GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh >&2)
  zig_line=$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true); rm -f "$zig_env"
  [[ -n "$zig_line" ]] && export "$zig_line"
fi
bin=$(build "$repo" "$repo/cmux-tui/target") || { echo "braid-dial-loss.sh: bench build failed at HEAD" >&2; exit 1; }
arms=(after); bins=("$bin"); shas=("$(git -C "$repo" rev-parse HEAD)")
work=$(mktemp -d)
if [[ -n "$before_ref" ]]; then
  fetch_depth=()
  [[ "$(git -C "$repo" rev-parse --is-shallow-repository)" == true ]] && fetch_depth=(--depth=1)
  git -C "$repo" cat-file -e "$before_ref^{commit}" 2>/dev/null || git -C "$repo" fetch -q "${fetch_depth[@]}" origin "$before_ref"
  git -C "$repo" worktree add -q --detach "$work/before" "$before_ref"
  bin=$(build "$work/before" "$repo/cmux-tui/target-before") || { echo "braid-dial-loss.sh: bench build failed at $before_ref" >&2; exit 1; }
  arms+=(before); bins+=("$bin"); shas+=("$(git -C "$work/before" rev-parse HEAD)")
fi
# root runs the bench inside the netns; a user-only FUSE checkout denies root exec, so run copies
for i in "${!bins[@]}"; do cp "${bins[$i]}" "$work/bench-${arms[$i]}"; bins[$i]="$work/bench-${arms[$i]}"; done

id=$$; c="bdl-$id-c"; s="bdl-$id-s"; vc="bdl${id}c"; vs="bdl${id}s"
cleanup() {
  [[ -n "${srv:-}" ]] && "${sudo[@]}" kill "$srv" 2>/dev/null || true
  "${sudo[@]}" ip netns del "$c" 2>/dev/null || true; "${sudo[@]}" ip netns del "$s" 2>/dev/null || true
  "${sudo[@]}" rm -f "/etc/netns/$c/hosts"; "${sudo[@]}" rmdir "/etc/netns/$c" 2>/dev/null || true
  [[ -d "$work/before" ]] && git -C "$repo" worktree remove --force "$work/before" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
"${sudo[@]}" ip netns add "$c"; "${sudo[@]}" ip netns add "$s"
"${sudo[@]}" ip link add "$vc" type veth peer name "$vs"
"${sudo[@]}" ip link set "$vc" netns "$c"; "${sudo[@]}" ip link set "$vs" netns "$s"
for ns in "$c" "$s"; do "${sudo[@]}" ip -n "$ns" link set lo up; done
"${sudo[@]}" ip -n "$c" addr add 10.78.0.1/24 dev "$vc"; "${sudo[@]}" ip -n "$c" addr add fd78::1/64 dev "$vc" nodad
"${sudo[@]}" ip -n "$s" addr add 10.78.0.2/24 dev "$vs"; "${sudo[@]}" ip -n "$s" addr add fd78::2/64 dev "$vs" nodad
"${sudo[@]}" ip -n "$c" link set "$vc" up; "${sudo[@]}" ip -n "$s" link set "$vs" up
"${sudo[@]}" mkdir -p "/etc/netns/$c"
printf 'fd78::2 braid-peer\n10.78.0.2 braid-peer\n' | "${sudo[@]}" tee "/etc/netns/$c/hosts" >/dev/null
"${sudo[@]}" ip netns exec "$s" python3 -c '
import socket
s=socket.socket(socket.AF_INET6); s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("::",7443)); s.listen(512)
while True:
    a,_=s.accept(); a.close()' &
srv=$!
sleep 0.3

shape() { # PCT: netem delay and loss on both ends (replace, so levels change in place).
  "${sudo[@]}" ip netns exec "$c" tc qdisc replace dev "$vc" root netem delay "${delay_ms}ms" loss "$1%"
  "${sudo[@]}" ip netns exec "$s" tc qdisc replace dev "$vs" root netem delay "${delay_ms}ms" loss "$1%"
}

for i in "${!arms[@]}"; do # an unshaped smoke dial per arm: a rig that cannot dial at all stops here, not as rows
  smoke=$("${sudo[@]}" ip netns exec "$c" "${bins[$i]}" braid-peer 7443 1 2>&1 || true) # whole output (grep -q + pipefail = SIGPIPE)
  [[ "$smoke" =~ (^|$'\n')'dial 0: '[0-9] ]] \
    || { echo "braid-dial-loss.sh: ${arms[$i]} arm cannot dial braid-peer unshaped:" >&2; echo "$smoke" >&2; exit 1; }
done

IFS=, read -ra levels <<<"$loss"
for pct in "${levels[@]}"; do
  shape "$pct"
  for i in "${!arms[@]}"; do : >"$work/${arms[$i]}-$pct.txt"; done
  for _ in $(seq "$n"); do
    for i in "${!arms[@]}"; do # interleaved: each round dials every arm once
      line=$("${sudo[@]}" ip netns exec "$c" "${bins[$i]}" braid-peer 7443 1 2>/dev/null | grep -m1 '^dial 0:' || true)
      echo "${line:-dial 0: failed}" >>"$work/${arms[$i]}-$pct.txt"
    done
  done
  for i in "${!arms[@]}"; do
    python3 -I - "$work/${arms[$i]}-$pct.txt" "${arms[$i]}" "${shas[$i]}" "$pct" "$delay_ms" <<'PY' | tee -a "$rows"
import json, re, sys
path, arm, sha, pct, delay = sys.argv[1:]
lines = open(path).read().splitlines()
t = sorted(float(m.group(1)) for l in lines if (m := re.match(r"dial 0: ([0-9.]+) ms", l)))
at = lambda p: t[min(len(t) - 1, ((len(t) - 1) * p + 50) // 100)] if t else None
print(json.dumps({"arm": arm, "sha": sha, "loss_pct": int(pct), "delay_ms": int(delay), "n": len(lines),
  "failed": len(lines) - len(t), "p50_ms": at(50), "p95_ms": at(95), "max_ms": t[-1] if t else None,
  "mean_ms": round(sum(t) / len(t), 1) if t else None}))
PY
  done
done
echo "braid-dial-loss.sh: rows in $rows"
