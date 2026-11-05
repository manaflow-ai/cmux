#!/usr/bin/env bash
# Projection window of a published cmux NEXT build on a fleet Mac with a console session (cmuxterm-hq#7149 row
# L10; scripts/ci/projection_check.py does the driving): this checkout's change shows in a projection window of
# the running NIGHTLY within 5 s of the save, the main windows untouched, one click runs a named test, and a
# theme and shortcut edit reload live.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/projection.sh --ref <sha> [--arg=dmg=nightly|URL | --arg=app=ZIP-URL | --arg=build=dev] \
#     --artifact .build/projection/report.tgz --timeout 1800  (build=dev: 5400, a DEV build and maybe a Zig download)
# Prints L10-STEP lines and one L10 {json} verdict (exit 3: the NIGHTLY predates projection windows).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/projection"
rm -rf "$out" && mkdir -p "$out"
dmg=nightly app="" extra=()
for arg in "$@"; do
  case "$arg" in
    dmg=nightly|dmg=https://*) dmg="${arg#dmg=}" ;;
    app=https://*) app="${arg#app=}" ;;
    build=dev) app=build ;;
    budget_ms=*) extra+=(--budget-ms "${arg#budget_ms=}") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
echo "L10 host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
if [[ "$app" == build ]]; then
  # This commit as a tagged DEV app built in the step (as scripts/measure/chat-open.sh does), for a commit no
  # NIGHTLY carries yet. A step's checkout has empty submodules: reload.sh needs Ghostty's headers.
  git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
  # cmux-tui's libghostty-vt builds with ghostty-next's Zig (`ZIG`, ghostty-vt-sys); a worker whose own Zig is
  # another version gets that one installed in the step, never in place of the worker's.
  need="$(source scripts/ghostty-zig-version.sh && GHOSTTY_ZIG_SOURCE=ghostty-next ghostty_minimum_zig_version "$PWD")"
  [[ -n "$need" ]] || { echo "L10 no Zig version in ghostty-next/build.zig.zon"; exit 3; }
  if [[ "$(zig version 2>/dev/null || true)" != "$need" ]]; then
    # A Zig the worker keeps with its other pinned tools (as bun), else one installed in the step. The
    # official server has run at ~60 KB/s (51 MB) while every mirror stalled: here all four sources are the
    # official one, resumed over up to 8 tries in 30 minutes (the installer's default is 2 tries a source in 8).
    ZIG=""
    for kept in "/Users/Shared/cmux-build-fleet/tools/zig-$need/zig" "/Users/Shared/cmux-build-fleet/tools/zig-$need/bin/zig"; do
      [[ -x "$kept" && "$("$kept" version 2>/dev/null)" == "$need" ]] && { ZIG="$kept"; break; }
    done
    if [[ -z "${ZIG:-}" ]]; then
      official="https://ziglang.org/download/$need/zig-$(uname -m | sed 's/arm64/aarch64/')-macos-$need.tar.xz"
      ZIG_FORCE_LOCAL_INSTALL=1 ZIG_REQUIRED="$need" ZIG_INSTALL_ROOT="$out/zig" RUNNER_TEMP="$out/zig-work" \
        ZIG_DOWNLOAD_BUDGET_SECONDS=1800 ZIG_DOWNLOAD_ATTEMPTS=8 \
        ZIG_MIRROR_URL="$official" ZIG_SECONDARY_MIRROR_URL="$official" ZIG_TERTIARY_MIRROR_URL="$official" \
        ./scripts/install-zig-ci.sh >"$out/zig.log" 2>&1 || { echo "L10 zig $need did not install"; tail -n 20 "$out/zig.log"; exit 3; }
      ZIG="$(find "$out/zig" -maxdepth 2 -name zig -type f -perm -u+x | head -n 1)"
    fi
    [[ -x "$ZIG" ]] || { echo "L10 no zig $need after the install"; exit 3; }
    export ZIG
    echo "L10 zig $need for ghostty-next: $ZIG"
  fi
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag l10proj 2>&1 | tee "$out/reload.log" >/dev/null
  bundle="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  [[ -n "$bundle" && -d "$bundle" ]] || { echo "L10 the tagged build printed no app"; grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 40; exit 3; }
  echo "L10 app $bundle (built here)"
elif [[ -n "$app" ]]; then
  # A built app (a fleet DEV build's cmux.app.zip), for a commit no NIGHTLY carries yet.
  echo "L10 app $app"
  curl -fsSL --proto '=https' --retry 3 -A cmux-projection/1 -o "$out/app.zip" "$app" || { echo "L10 download failed"; exit 3; }
  ditto -x -k "$out/app.zip" "$out/app" && rm -f "$out/app.zip"
  bundle="$(find "$out/app" -maxdepth 2 -name '*.app' -type d | head -1)"
  [[ -n "$bundle" ]] || { echo "L10 no app in the zip"; exit 3; }
fi
if [[ -n "$app" ]]; then
  python3 scripts/ci/projection_check.py --app "$bundle" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
  rc=${PIPESTATUS[0]}
  tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz --exclude app . 2>/dev/null || true
  exit "$rc"
fi
if [[ "$dmg" == nightly ]]; then
  feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"  # the one feed since #36287
  curl -fsSL --proto '=https' --retry 3 -A cmux-projection/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" || { echo "L10 feed download failed"; exit 3; }
  picked="$(python3 scripts/ci/nightly_next_launch_smoke.py pick --feed "$out/feed.xml")" || { echo "L10 no nightly build on the feed"; exit 3; }
  echo "$picked" | sed 's/^/L10 pick /'
  dmg="$(sed -n 's/^url=//p' <<<"$picked")"
fi
echo "L10 dmg $dmg"
curl -fsSL --proto '=https' --retry 3 -A cmux-projection/1 -o "$out/in.dmg" "$dmg" || { echo "L10 download failed"; exit 3; }
python3 scripts/ci/projection_check.py --dmg "$out/in.dmg" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
rm -f "$out/in.dmg"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$rc"
