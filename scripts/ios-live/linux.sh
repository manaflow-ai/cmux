#!/usr/bin/env bash
# ios-live on a Linux phone: the host side for an agent-sim iPhone (Apple's iOS runtime on x86-64 Linux).
#
# Runs ON a Linux host with agent-sim set up (`agent-sim setup`, or a linux-simsdk runner with its pool booted).
# scripts/ios-live/ios-live calls it when IOS_LIVE_LINUX names the host (`local` runs it here, with no reach).
# The host keeps, under IOS_LIVE_ROOT (default ~/ios-live-linux):
#   phone         the agent-sim phone this host's slot holds (taken from the pool once, kept booted)
#   app/          the last installed CmuxMobileApp.app
#   launch.env    KEY=VALUE lines passed to the app as its launch environment
#   state.json    phone, bundle id, app digest, timings of the last swap
#
# Commands:
#   take                 hold a booted phone (pool take; else the setup phone `p`, booted with `up`); prints it
#   swap APP|TARBALL     install this build and relaunch it, then wait until it is on screen; prints timings
#   relaunch             terminate and launch the installed app with launch.env
#   shot OUT.png | tree | tap X Y | type TEXT | status | release
#
# What a swap costs here is install + relaunch + first frame: the phone stays booted between swaps, so no boot
# (44 s) and no queue. The build that makes APP happens wherever a cmux NEXT simulator build runs today (an ios-live
# Mac slot, or the ios-sim-linux-build workflow's ios-sim-build artifact).
set -euo pipefail

root="${IOS_LIVE_ROOT:-$HOME/ios-live-linux}"
sim="${AGENT_SIM:-agent-sim}"
mkdir -p "$root"
die() { echo "ios-live-linux: $*" >&2; exit 1; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
command -v "$sim" >/dev/null 2>&1 || die "no agent-sim on $(hostname -s) (agent-sim setup)"

state_set() {  # state_set KEY=VALUE...: merged into state.json
  python3 -I - "$root/state.json" "$@" <<'PY'
import json, sys, os
path, pairs = sys.argv[1], sys.argv[2:]
try:
    doc = json.load(open(path))
except (OSError, ValueError):
    doc = {}
for p in pairs:
    k, v = p.split("=", 1)
    doc[k] = int(v) if v.lstrip("-").isdigit() else v
tmp = path + ".tmp"
json.dump(doc, open(tmp, "w"), indent=1, sort_keys=True)
os.replace(tmp, path)
PY
}
state_get() { python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except (OSError, ValueError): print("")' "$root/state.json" "$1"; }

phone() {
  local p; p="$(cat "$root/phone" 2>/dev/null || true)"
  [[ -n "$p" ]] || die "this host's slot holds no phone (linux.sh take)"
  echo "$p"
}

take() {
  local p
  if p="$(cat "$root/phone" 2>/dev/null)" && [[ -n "$p" ]]; then echo "$p"; return; fi
  if p="$("$sim" pool take 2>/dev/null)" && [[ -n "$p" ]]; then
    :
  else
    p=p
    "$sim" --device "$p" up >/dev/null
  fi
  echo "$p" >"$root/phone"
  echo "$p"
}

release() {
  local p; p="$(phone)"
  if [[ "$p" == pool* ]]; then "$sim" pool release "$p" >/dev/null 2>&1 || true; fi
  rm -f "$root/phone"
  echo "released $p"
}

launch_env_args() {
  [[ -f "$root/launch.env" ]] || return 0
  grep -v '^[[:space:]]*\(#\|$\)' "$root/launch.env" | sed 's/^/--env\n/' || true
}

# unpack SRC: SRC is a .app directory, or a tarball holding one (ios-sim-build.tar.gz: Products/<config>-iphonesimulator/
# CmuxMobileApp.app). Leaves the app at $root/app/<name>.app and prints that path.
unpack() {
  local src="$1" found
  rm -rf "$root/app.new" && mkdir -p "$root/app.new"
  if [[ -d "$src" ]]; then
    cp -a "$src" "$root/app.new/"
  else
    tar -C "$root/app.new" -xzf "$src" 2>/dev/null || tar -C "$root/app.new" -xf "$src"
  fi
  found="$(find "$root/app.new" -maxdepth 4 -type d -name 'CmuxMobileApp.app' | head -n 1)"
  [[ -n "$found" ]] || found="$(find "$root/app.new" -maxdepth 4 -type d -name '*.app' ! -name '*-Runner.app' | head -n 1)"
  [[ -n "$found" ]] || die "no .app in $src"
  rm -rf "$root/app" && mkdir -p "$root/app"
  mv "$found" "$root/app/"
  rm -rf "$root/app.new"
  echo "$root/app/$(basename "$found")"
}

bundle_of() {
  python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1]+"/Info.plist","rb"))["CFBundleIdentifier"])' "$1"
}

launch() {  # launch BUNDLE: terminate, then launch with launch.env
  local p="$1" b="$2" args=()
  while IFS= read -r w; do args+=("$w"); done < <(launch_env_args)
  "$sim" --device "$p" terminate "$b" >/dev/null 2>&1 || true
  "$sim" --device "$p" launch ${args[@]+"${args[@]}"} "$b" >/dev/null
}

# visible PHONE BUNDLE BOUND_S: until the app is in front with at least one element of its own on screen.
visible() {
  local p="$1" b="$2" bound="${3:-60}" end out
  end=$(( $(date +%s) + bound ))
  while (( $(date +%s) < end )); do
    out="$("$sim" --device "$p" snapshot 2>/dev/null || true)"
    if grep -q "^app $b\$" <<<"$out" && (( $(grep -c '^@e' <<<"$out") > 0 )); then return 0; fi
    sleep 0.2
  done
  return 1
}

swap() {
  local src="${1:?swap APP|TARBALL}" p app b t0 t1 t2 t3 t4 digest
  p="$(phone)"
  t0=$(now_ms)
  app="$(unpack "$src")"; b="$(bundle_of "$app")"
  digest="$(find "$app" -type f -name "$(basename "$app" .app)" -exec sha256sum {} + | cut -c1-12)"
  t1=$(now_ms)
  "$sim" --device "$p" install "$app" >"$root/install.log" 2>&1 || { cat "$root/install.log" >&2; die "install failed"; }
  t2=$(now_ms)
  launch "$p" "$b"
  t3=$(now_ms)
  visible "$p" "$b" "${IOS_LIVE_VISIBLE_S:-90}" || die "$b launched but never reached the screen in ${IOS_LIVE_VISIBLE_S:-90} s"
  t4=$(now_ms)
  state_set phone="$p" bundle_id="$b" app="$app" binary="$digest" last_kind=swap \
    unpack_ms=$((t1-t0)) install_ms=$((t2-t1)) launch_ms=$((t3-t2)) first_frame_ms=$((t4-t3)) total_ms=$((t4-t0)) \
    at="$(date -u +%FT%TZ)"
  cat "$root/state.json"
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  take) take ;;
  release) release ;;
  swap) swap "$@" ;;
  relaunch) p="$(phone)"; b="$(state_get bundle_id)"; [[ -n "$b" ]] || die "nothing installed yet (swap first)"
    t0=$(now_ms); launch "$p" "$b"; visible "$p" "$b" 90 || die "not on screen"; state_set relaunch_ms=$(( $(now_ms)-t0 )); echo "relaunched $b" ;;
  shot) "$sim" --device "$(phone)" screenshot -o "${1:?shot OUT.png}" >/dev/null; echo "$1" ;;
  tree) "$sim" --device "$(phone)" snapshot ;;
  tap) "$sim" --device "$(phone)" tap "${1:?x}" "${2:?y}" ;;
  type) "$sim" --device "$(phone)" type "${1:?text}" ;;
  status) echo "host $(hostname -s) phone $(cat "$root/phone" 2>/dev/null || echo none)"; cat "$root/state.json" 2>/dev/null || true ;;
  *) die "unknown command $cmd (take, swap, relaunch, shot, tree, tap, type, status, release)" ;;
esac
