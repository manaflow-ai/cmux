#!/usr/bin/env bash
# Screen Sharing under netem, before and after a change: builds `cmux-rd` at BASE (a git ref)
# and at this checkout, then runs screen-share-netem.py with both on the same rows, 1080p motion
# by default. For a lossy, slow path (hq#19915: a 1080p motion keyframe is 400-550 datagrams).
#
#   BASE=origin/feat-cmux-next ROWS="60:2:8 60:5:8" bash netem-before-after.sh [OUT_DIR]
#
# ROWS: space-separated RTT_MS:LOSS_PCT:RATE_MBIT (rate 0: no cap). ATTEMPTS, SAMPLES, WORKLOAD
# go to the harness. Needs passwordless sudo (network namespaces, tc), Xvfb and ethtool; on
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
: "${ATTEMPTS:=3}" "${SAMPLES:=20}" "${WORKLOAD:=motion}"

missing=()
for tool in Xvfb ethtool tc; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if ((${#missing[@]})); then
  sudo -n apt-get update -qq >/dev/null && sudo -n apt-get install -y -qq xvfb ethtool iproute2 >/dev/null ||
    { echo "netem-before-after: cannot install ${missing[*]}" >&2; exit 2; }
fi

features=(--no-default-features --features bench,link,portal-dbus)
build() { # build DIR TARGET -> path of cmux-rd
  CARGO_TARGET_DIR="$2" cargo build --release --quiet --manifest-path "$1/cmux-tui/crates/cmux-rd-host/Cargo.toml" \
    --bin cmux-rd "${features[@]}" >&2 || return 1
  echo "$2/release/cmux-rd"
}

git -C "$repo" fetch -q origin "${BASE#origin/}" 2>/dev/null
base_sha="$(git -C "$repo" merge-base HEAD "$BASE")" || { echo "no merge base with $BASE" >&2; exit 2; }
base_dir="$(mktemp -d)/base"
git -C "$repo" worktree add -q --detach "$base_dir" "$base_sha" || exit 2
# cmux-rd-host is its own workspace, so its default target is the crate's own.
target="${CARGO_TARGET_DIR:-$crate/target}"
head_bin="$(build "$repo" "$target")" || { echo "head build failed" >&2; exit 1; }
base_bin="$(build "$base_dir" "$target-base")" || { echo "base build failed" >&2; exit 1; }
echo "base $base_sha, head $(git -C "$repo" rev-parse HEAD)"

for row in $ROWS; do
  IFS=: read -r rtt loss rate <<<"$row"
  for side in base head; do
    bin="$base_bin"; [[ $side == head ]] && bin="$head_bin"
    file="$out/$side-$rtt-$loss-$rate.jsonl"
    sudo -n python3 -I "$here/screen-share-netem.py" "$bin" --rtt "$rtt" --loss "$loss" --rate "$rate" \
      --workload "$WORKLOAD" --attempts "$ATTEMPTS" --samples "$SAMPLES" --out "$file" >"$file.log" 2>&1
    echo "$side rtt=${rtt}ms loss=${loss}% rate=${rate}Mbit exit=$?: $(tail -n 3 "$file.log" | tr '\n' ' ')"
  done
done
git -C "$repo" worktree remove --force "$base_dir"
