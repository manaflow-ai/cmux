#!/usr/bin/env bash
# Screen Sharing under netem, before and after a change: builds `cmux-rd` at BASE (a git ref)
# and at this checkout, then runs screen-share-netem.py with both on the same rows, 1080p motion
# by default. For a lossy, slow path (hq#19915: a 1080p motion keyframe is 400-550 datagrams).
#
#   BASE=origin/feat-cmux-next ROWS="60:2:8 60:5:8" bash netem-before-after.sh [OUT_DIR]
#
# ROWS: space-separated RTT_MS:LOSS_PCT:RATE_MBIT (rate 0: no cap). ATTEMPTS, SAMPLES, WORKLOAD
# go to the harness. SERVE_ARGS (space-separated) go to both hosts' `cmux-rd serve`, e.g.
# SERVE_ARGS="--resolution-ladder 1". Needs passwordless sudo (network namespaces, tc), Xvfb and ethtool; on
# Ubuntu it installs what is missing. Writes OUT_DIR/{base,head}-RTT-LOSS-RATE.jsonl and prints
# one summary line per run.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
crate="$(dirname "$here")"
repo="$(git -C "$crate" rev-parse --show-toplevel)"
out="${1:-${FAST_CHECKS_OUT:-/tmp}/netem-before-after}"
mkdir -p "$out"
: "${BASE:=origin/feat-cmux-next}"
: "${ROWS:=60:2:8 60:5:8 60:2:0}"
: "${ATTEMPTS:=3}" "${SAMPLES:=20}" "${WORKLOAD:=motion}" "${SERVE_ARGS:=}"
serve_args=()
for a in $SERVE_ARGS; do serve_args+=(--serve-arg="$a"); done

missing=()
for tool in Xvfb ethtool tc; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if ((${#missing[@]})); then
  sudo -n apt-get update -qq >/dev/null && sudo -n apt-get install -y -qq xvfb ethtool iproute2 >/dev/null ||
    { echo "netem-before-after: cannot install ${missing[*]}" >&2; exit 2; }
fi
# A kernel without sch_netem (the Blacksmith image) fails every row's tc; say so before building.
sudo -n modprobe sch_netem 2>/dev/null
sudo -n ip link add rdnetem-probe type dummy 2>/dev/null &&
  { sudo -n tc qdisc add dev rdnetem-probe root netem delay 1ms; ok=$?; sudo -n ip link del rdnetem-probe; } ||
  ok=1
((ok == 0)) || { echo "netem-before-after: this kernel ($(uname -r)) has no netem qdisc" >&2; exit 2; }

features=(--no-default-features --features bench,link,portal-dbus)
build() { # build DIR TARGET -> path of cmux-rd
  CARGO_TARGET_DIR="$2" cargo build --release --quiet --manifest-path "$1/cmux-tui/crates/cmux-rd-host/Cargo.toml" \
    --bin cmux-rd "${features[@]}" >&2 || return 1
  echo "$2/release/cmux-rd"
}

# BASE_SHA names the base commit outright. Otherwise the merge base with BASE; a shallow CI
# checkout has none, so fetch BASE and deepen until there is one.
base_sha="${BASE_SHA:-}"
if [[ -z $base_sha ]]; then
  git -C "$repo" fetch -q origin "+refs/heads/${BASE#origin/}:refs/remotes/$BASE" 2>/dev/null
  for depth in 200 2000 20000; do
    base_sha="$(git -C "$repo" merge-base HEAD "$BASE" 2>/dev/null)" && break
    git -C "$repo" fetch -q --deepen="$depth" origin HEAD "${BASE#origin/}" 2>/dev/null
  done
fi
[[ -n $base_sha ]] && git -C "$repo" cat-file -e "$base_sha^{commit}" 2>/dev/null ||
  git -C "$repo" fetch -q origin "$base_sha" 2>/dev/null ||
  { echo "no merge base with $BASE (set BASE_SHA)" >&2; exit 2; }
base_dir="$(mktemp -d)/base"
git -C "$repo" worktree add -q --detach "$base_dir" "$base_sha" || exit 2
# cmux-rd-host is its own workspace, so its default target is the crate's own.
target="${CARGO_TARGET_DIR:-$crate/target}"
head_bin="$(build "$repo" "$target")" || { echo "head build failed" >&2; exit 1; }
base_bin="$(build "$base_dir" "$target-base")" || { echo "base build failed" >&2; exit 1; }
echo "base $base_sha, head $(git -C "$repo" rev-parse HEAD)"

failed=0
for row in $ROWS; do
  IFS=: read -r rtt loss rate <<<"$row"
  for side in base head; do
    bin="$base_bin"; [[ $side == head ]] && bin="$head_bin"
    file="$out/$side-$rtt-$loss-$rate.jsonl"
    sudo -n python3 -I "$here/screen-share-netem.py" "$bin" --rtt "$rtt" --loss "$loss" --rate "$rate" \
      --workload "$WORKLOAD" --attempts "$ATTEMPTS" --samples "$SAMPLES" "${serve_args[@]}" --out "$file" >"$file.log" 2>&1
    rc=$?
    ((rc == 0)) || failed=$((failed + 1))
    echo "$side rtt=${rtt}ms loss=${loss}% rate=${rate}Mbit exit=$rc: $(tail -n 3 "$file.log" | tr '\n' ' ')" |
      tee -a "$out/summary.txt"
  done
done
git -C "$repo" worktree remove --force "$base_dir"
# A run whose rows failed measured nothing: exit non-zero so its CI verdict is not green.
((failed == 0)) || { echo "netem-before-after: $failed run(s) failed" >&2; exit 1; }
