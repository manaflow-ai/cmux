#!/usr/bin/env bash
# Bytes per terminal scroll step and per `_acpmux/session_changed`, before and after, through the
# network-conditions harness's link shaper (cmux-fault Shaper, link-profiles.json), under duress:
# a 20,000-line terminal that keeps streaming 20 lines/s while the phone scrolls up 10 history
# fetches, and a 10,000-turn chat streaming a chunk every 50 ms.
#
#   cmux-ci test -- scripts/measure/mobile-bandwidth-steps.sh [tree=SHA[:BENCHES] ...] [profiles=lte,good-wifi]
#
# BENCHES is a +-list of scroll (terminal_scroll_steps), chat (chat_bytes_per_minute's
# bytes_per_session_changed) and pan (alt_screen_pan_bytes: bytes per one-finger pan over a
# full-screen app streaming 20 lines/s); default scroll+chat. caps= (comma list) adds capabilities
# the pan bench's phone declares (NETCOND_PAN_CAPS), the same on every tree. Pairs: tree=BEFORE:chat tree=AFTER:chat.
#
# Each tree gets this checkout's yardstick laid over it (the shaper, the profiles and the two bench
# files with their counters: cmux-tui `terminal_scroll_steps`, acpmux `chat_bytes_per_minute`'s
# `bytes_per_session_changed`), so only the code under test differs. The exit is the benches' own:
# set -o pipefail, and a failing cargo test fails the run.
set -euo pipefail

trees=() profiles="lte,good-wifi" bw_secs=30 caps=""
for kv in "$@"; do
  case "$kv" in
    tree=*) trees+=("${kv#*=}") ;;
    profiles=*) profiles="${kv#*=}" ;;
    bw_secs=*) bw_secs="${kv#*=}" ;;
    caps=*) caps="${kv#*=}" ;;
    *) echo "mobile-bandwidth-steps.sh: unknown arg '$kv' (tree=SHA[:scroll+chat+pan], profiles=, bw_secs=, caps=)" >&2; exit 2 ;;
  esac
done
(( ${#trees[@]} )) || trees=(281ddcf1e80359887affccf1975041d8d8f7db76 64863a5779c49073e5c0bb709dd5620dd37ffb20)

root="$(git rev-parse --show-toplevel)"
work="$root/.build/mobile-bandwidth-steps"
rm -rf "$work"
mkdir -p "$work"
out="${FAST_CHECKS_OUT:-$work}"
mkdir -p "$out"
fetch_url="$(git remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)"
echo "STEPS-MACHINE host=$(hostname) os=$(uname -sr) cores=$(getconf _NPROCESSORS_ONLN) yardstick=$(git rev-parse HEAD) load=\"$(cut -d' ' -f1-3 /proc/loadavg)\""
# A bare runner (the cmux-ci test runner has no Zig: ghostty-vt-sys's `zig build` hit ENOENT, job
# 118101e834ec461bb966788c62f66d23): install the pinned Zig exactly as terminal-scroll-stress-linux.sh does (#50961).
[ -f "$root/ghostty-next/build.zig" ] || [ -n "${CMUX_GHOSTTY_SRC:-}" ] || git -C "$root" submodule update --init --depth 1 ghostty-next
if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
  # The pinned Zig is ghostty-next's. A runner without passwordless sudo gets it under RUNNER_TEMP, published only
  # through GITHUB_ENV: read CMUX_ZIG back from a file of our own (as infinite-items-linux.sh does).
  zig_env="$(mktemp)"
  (cd "$root" && GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh) >&2
  zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
  rm -f "$zig_env"
  [ -z "$zig_line" ] || export "$zig_line"
  # ghostty-vt-sys runs a bare `zig`: put the job-local one on PATH.
  [ -z "${CMUX_ZIG:-}" ] || export PATH="$(dirname "$CMUX_ZIG"):$PATH"
fi
echo "STEPS-ZIG ${CMUX_ZIG:-$(command -v zig || echo none)}"

yardstick=(
  cmux-tui/crates/cmux-fault/src/shaper.rs
  cmux-tui/crates/cmux-fault/src/shaper/udp.rs
  cmux-tui/crates/cmux-fault/src/lib.rs
  cmux-tui/crates/cmux-fault/Cargo.toml
  cmux-tui/crates/cmux-fault/link-profiles.json
  cmux-tui/crates/cmux-tui/tests/mobile_link_conditions.rs
  cmux-tui/crates/acpmux/tests/mobile_link_conditions.rs
)
cleanup() { for t in ${trees[@]+"${trees[@]}"}; do git -C "$root" worktree remove --force "$work/${t%%:*}" 2>/dev/null || true; done; }
trap cleanup EXIT

: >"$out/lines.txt"
for spec in ${trees[@]+"${trees[@]}"}; do
  tree="${spec%%:*}" benches="scroll+chat"
  [[ "$spec" == *:* ]] && benches="${spec#*:}"
  [[ "$tree" =~ ^[0-9a-f]{40}$ ]] || { echo "mobile-bandwidth-steps.sh: tree= is a 40-character SHA" >&2; exit 2; }
  [[ "+$benches+" =~ ^(\+(scroll|chat|pan))+\+$ ]] || { echo "mobile-bandwidth-steps.sh: benches are scroll, chat, pan joined by +" >&2; exit 2; }
  src="$work/$tree"
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  git fetch --no-recurse-submodules -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$tree"
  git worktree add -q --detach "$src" "$tree"
  git -C "$src" submodule update --init --depth 1 ghostty-next >/dev/null
  for f in "${yardstick[@]}"; do mkdir -p "$(dirname "$src/$f")"; cp "$root/$f" "$src/$f"; done
  echo "STEPS-TREE $tree: yardstick $(git rev-parse HEAD) laid over it, benches $benches"
  if [[ "+$benches+" == *+pan+* ]]; then
    log="$work/$tree-pan.log"
    set +e
    (cd "$src/cmux-tui" && CARGO_TARGET_DIR="$work/target" NETCOND_PROFILES="$profiles" NETCOND_PAN_CAPS="$caps" \
      cargo test --release -p cmux-tui --test mobile_link_conditions -- \
        --ignored --nocapture --test-threads 1 --exact alt_screen_pan_bytes 2>&1) | tee "$log" \
      | grep -E '^(NETCOND|test |error)'
    code=${PIPESTATUS[0]}
    set -e
    sed -n "s/^NETCOND /$tree /p" "$log" >>"$out/lines.txt"
    (( code == 0 )) || { tail -n 60 "$log"; echo "STEPS-FAIL $tree pan exit=$code"; exit "$code"; }
  fi
  if [[ "+$benches+" == *+scroll+* ]]; then
  log="$work/$tree-terminal.log"
  set +e
  (cd "$src/cmux-tui" && CARGO_TARGET_DIR="$work/target" NETCOND_PROFILES="$profiles" \
    cargo test --release -p cmux-tui --test mobile_link_conditions -- \
      --ignored --nocapture --test-threads 1 --exact terminal_scroll_steps 2>&1) | tee "$log" \
    | grep -E '^(NETCOND|test |error)'
  # The bench's exit, not tee's or grep's (grep finding nothing is not a failure).
  code=${PIPESTATUS[0]}
  set -e
  sed -n "s/^NETCOND /$tree /p" "$log" >>"$out/lines.txt"
  (( code == 0 )) || { tail -n 60 "$log"; echo "STEPS-FAIL $tree terminal exit=$code"; exit "$code"; }
  fi
  [[ "+$benches+" == *+chat+* ]] || continue
  IFS=, read -r -a plist <<<"$profiles"
  for p in "${plist[@]}"; do
    log="$work/$tree-chat-$p.log"
    set +e
    (cd "$src/cmux-tui" && CARGO_TARGET_DIR="$work/target" NETCOND_BW_PROFILE="$p" NETCOND_BW_APPS=ios \
      NETCOND_BW_SECS="$bw_secs" NETCOND_BW_TURNS=10000 \
      cargo test --release -p acpmux --test mobile_link_conditions -- \
        --ignored --nocapture --test-threads 1 --exact chat_bytes_per_minute 2>&1) | tee "$log" \
      | grep -E '^(NETCOND|netcond-bw|test |error)'
    code=${PIPESTATUS[0]}
    set -e
    sed -n "s/^NETCOND /$tree /p" "$log" >>"$out/lines.txt"
    (( code == 0 )) || { tail -n 60 "$log"; echo "STEPS-FAIL $tree chat $p exit=$code"; exit "$code"; }
  done
done

python3 - "$out/lines.txt" <<'PY' | tee "$out/summary.txt"
import json, sys, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    tree, _, js = line.partition(" ")
    r = json.loads(js)
    if r.get("value") is None:
        continue
    phase = r["phase"] + ("_idle" if r["scale"] == "idle" else "")
    rows[(tree[:10], r["profile"], phase, r["metric"])].append((r["scale"], r["value"]))
for (tree, prof, phase, metric), vals in sorted(rows.items()):
    if phase == "scroll_step" and metric in ("bytes_down", "replay_bytes", "rows_asked", "step_ms", "streamed_bytes"):
        v = [x for _, x in sorted(vals)]
        print(f"STEPS-SUMMARY {tree} {prof} scroll_step {metric} n={len(v)} mean={sum(v)/len(v):.0f} first={v[0]:.0f} last={v[-1]:.0f} all={','.join(f'{x:.0f}' for x in v)}")
    elif phase == "alt_pan_idle":
        print(f"STEPS-SUMMARY {tree} {prof} alt_pan_idle {metric} {vals[0][1]:.0f}")
    elif phase == "alt_pan" and metric in ("bytes_down", "bytes_up", "sends", "wheel_reports", "output_bytes", "send_reply_bytes", "pan_ms", "full_redraws", "full_redraw_bytes", "incremental_output_bytes", "frame_events", "frame_bytes", "shaper_down_bytes"):
        v = [x for _, x in sorted(vals)]
        print(f"STEPS-SUMMARY {tree} {prof} alt_pan {metric} n={len(v)} mean={sum(v)/len(v):.0f} all={','.join(f'{x:.0f}' for x in v)}")
    elif metric in ("bytes_per_session_changed", "session_changed_msgs", "session_patch_msgs"):
        print(f"STEPS-SUMMARY {tree} {prof} {phase} {metric} {vals[0][1]:.0f}")
PY
