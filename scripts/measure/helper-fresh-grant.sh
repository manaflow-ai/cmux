#!/usr/bin/env bash
# A grant made while cmux runs is used without restarting cmux (cmux#49813). Leo, 2026-11-22: "we need to get a
# handle on that sort of situation with the whole screen share/computer use and whatnot so i dont have to restart
# my app just to enable accessibility grants".
#
# On a SIP-off fleet Mac (the AWS Macs: SIP off, sudo without a password), in its console session:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
#     --script scripts/measure/helper-fresh-grant.sh --ref <sha> --target-worker aws-m4pro-N --pin-strict \
#     --artifact .build/helper-fresh-grant/report.tgz --timeout 5400 [--arg=ref=<sha to build>] [--arg=share=0]
#   --arg=ref=SHA  the commit whose app to build (40 hex; default: this checkout), in its own worktree, so a PR
#                  head is proven with this script from a reviewed commit (as fresh-home-launch.sh's ref=).
#   --arg=share=0  skip part c.
#
# It builds the tagged app (scripts/reload.sh, as fresh-home-launch.sh does), whose Screen Sharing
# helper (`<app> Screen Sharing.app`, `cmux-screen-sharing`) runs the Computer Use worker, then
# helper-fresh-grant.py:
#   a  the helper's Accessibility, PostEvent and Screen Recording rows removed; the app and its daemon started;
#      `cmux computer-use status` reads missing and a screenshot fails; the rows written (TCC.db, SIP off);
#      status must read granted and a screenshot succeed, with the app and daemon the same processes.
#   b  Computer Use lists apps, screenshots TextEdit and clicks and types into it, read back by its UI tree.
#   c  the helper's own `host` (the cmux.rd/1 share host), started as its own responsible process, streams to a
#      `cmux-rd bench` viewer on this Mac (the loopback-bench.sh shape) that decodes its frames.
# It refuses (exit 3) on a Mac with SIP on: agents write TCC.db only on a SIP-off CI fixture (cmuxterm-hq
# docs/handbook/screen-share-grant-lost-on-a-fleet-mac.md). Exit 0 when a, b and c pass, 1 when one failed,
# 3 when it could not run. Prints HFG lines; report.tgz holds report.json and the screenshots.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$PWD"
share=1 ref=""
for arg in "$@"; do
  case "$arg" in
    share=0|share=1) share="${arg#share=}" ;;
    ref=*) ref="${arg#ref=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
csrutil status 2>/dev/null | grep -q 'disabled' || { echo "HFG cannot run: SIP is on here (csrutil status: $(csrutil status 2>&1))" >&2; exit 3; }
sudo -n true 2>/dev/null || { echo "HFG cannot run: no passwordless sudo for the system TCC database" >&2; exit 3; }
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
work="" app="" build_tmp="" scratch="" src="$here"
cleanup() {
  local code=$?
  [ -n "$app" ] && [ -d "$app" ] && python3 "$here/scripts/cmux-next/tag_teardown.py" "$app" >/dev/null 2>&1
  if [ -n "$scratch" ]; then
    git -C "$here" worktree remove --force "$src" >/dev/null 2>&1
    rm -rf "$scratch"
  fi
  [ -n "$work" ] && rm -rf "$work"
  [ -n "$build_tmp" ] && rm -rf "$build_tmp"
  exit "$code"
}
trap cleanup EXIT
tmp_root="${TMPDIR:-/tmp}"; tmp_root="${tmp_root%/}"
build_tmp="$(mktemp -d "$tmp_root/helper-fresh-grant-build.XXXXXX")" || exit 3
export TMPDIR="$build_tmp/"
out="$here/.build/helper-fresh-grant"
rm -rf "$out" && mkdir -p "$out"
if [[ -n "$ref" && "$ref" != "$(git rev-parse HEAD)" ]]; then
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "ref= must be a 40-hex commit" >&2; exit 2; }
  if ! git cat-file -e "$ref^{commit}" 2>/dev/null; then
    fetched=false depth=()
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
    for remote in origin /Users/Shared/cmux-build-fleet/git/cmux.git https://github.com/manaflow-ai/cmux.git; do
      git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$ref" 2>/dev/null && { fetched=true; break; }
    done
    $fetched || { echo "HFG cannot fetch $ref" >&2; exit 3; }
  fi
  scratch="$(mktemp -d)"
  src="$scratch/src"
  git worktree add --quiet --detach "$src" "$ref" || exit 3
fi
cd "$src"
sha="$(git rev-parse HEAD)"
tag="freshgrant-${sha:0:8}"
echo "HFG macOS $(sw_vers -productVersion) app commit $sha harness commit $(git -C "$here" rev-parse HEAD) $(csrutil status)"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" || exit 3
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh || exit 3
fi
work="$(mktemp -d)"
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
if [ -n "$account_home" ]; then
  [ -z "${RUSTUP_HOME:-}" ] && [ -d "$account_home/.rustup" ] && export RUSTUP_HOME="$account_home/.rustup"
  [ -z "${CARGO_HOME:-}" ] && [ -d "$account_home/.cargo" ] && export CARGO_HOME="$account_home/.cargo"
fi
RUNNER_TEMP="$work" GITHUB_PATH="$work/bun-path" ./scripts/cmux-next/private-bun.sh || exit 3
PATH="$(tail -n 1 "$work/bun-path"):$PATH"
export PATH
cache="${CI_SHARED_CACHE_DIR:-/Users/Shared/cmux-build-fleet/cache}/helper-fresh-grant"
if [[ -z "${CMUX_TUI_CLIENT_LOCAL:-}" ]] && ! ./scripts/cmux-next/pin-cmux-tui.sh probe 2>/dev/null | grep -q ': ready ('; then
  echo "HFG cmux-tui tree not published: building the client set on this host"
  export CMUX_TUI_CLIENT_TARGET_DIR="${CMUX_TUI_CLIENT_TARGET_DIR:-$cache/cmux-tui-target}"
  mkdir -p "$CMUX_TUI_CLIENT_TARGET_DIR" cmux-tui/target
  CMUX_TUI_CLIENT_LOCAL="$(CI=1 ./scripts/cmux-next/build-cmux-tui-client.sh --print-path 2> >(tee "$out/cmux-tui-build.log" >&2))" || {
    echo "HFG cannot run: building cmux-tui failed" >&2
    tail -n 40 "$out/cmux-tui-build.log" >&2
    exit 3
  }
  export CMUX_TUI_CLIENT_LOCAL
fi
t0=$(date +%s)
CI=1 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links >"$out/reload.log" 2>&1
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "HFG cannot run: the tagged build printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2
  tail -n 30 "$out/reload.log" >&2
  exit 3
fi
echo "HFG built $app in $(( $(date +%s) - t0 )) s"
grep -E "Screen Sharing helper" "$out/reload.log" | head -n 5
viewer=""
if [ "$share" = 1 ]; then
  # The share viewer: cmux-rd with its default features (bench), as loopback-bench.sh and screen-share-vs.py use.
  t0=$(date +%s)
  mkdir -p "$cache/rd-target"
  if (cd cmux-tui/crates/cmux-rd-host && CARGO_TARGET_DIR="$cache/rd-target" cargo build --release --bin cmux-rd) >"$out/rd-build.log" 2>&1; then
    viewer="$cache/rd-target/release/cmux-rd"
    echo "HFG built the cmux-rd bench viewer in $(( $(date +%s) - t0 )) s"
  else
    echo "HFG the cmux-rd bench viewer did not build (rd-build.log); part c is not run" >&2
    tail -n 20 "$out/rd-build.log" >&2
  fi
  swiftc -O -o "$work/cmux-rd-marker" cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift >"$out/marker-build.log" 2>&1 ||
    echo "HFG the marker did not build (marker-build.log)" >&2
  clang -O2 -o "$work/disclaim" "$here/scripts/measure/helper-fresh-grant/disclaim.c" >"$out/disclaim-build.log" 2>&1 ||
    echo "HFG the disclaim launcher did not build (disclaim-build.log)" >&2
fi
python3 -I "$here/scripts/measure/helper-fresh-grant.py" --app "$app" --out "$out" --work "$work" \
  --account-home "$account_home" --viewer "$viewer" --marker "$work/cmux-rd-marker" --disclaim "$work/disclaim" --share "$share"
status=$?
echo "HFG exit $status"
tar -czf "$out.tgz" -C "$out" . && mv "$out.tgz" "$out/report.tgz"
exit $status
