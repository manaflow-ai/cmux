#!/usr/bin/env bash
# Run-time half of the macOS cross-compile parity proof, on a Mac (fleet host,
# never a developer laptop). scripts/ci/macho_parity.py compares the files on
# Linux; this script checks what only macOS can: that each Linux-built binary
# loads and runs like the Mac-built one of the same commit.
#
# usage: scripts/ci/macos-cross-runtime-check.sh <linux-dir> <mac-dir>
#   Both directories hold the files under their published names
#   (cmux-tui-aarch64-apple-darwin, cmux-tui-hook-..., cmux-relay-..., ...);
#   `scripts/ci/macos-cross.sh fetch-refs` writes the Mac set.
#
# Per binary of this Mac's architecture: LC_BUILD_VERSION platform/minos and
# the linked dylibs equal the Mac build's (otool), the ad-hoc signature is
# valid (codesign --verify --strict), and `version`/`--version` print the same
# text. Then cmux-tui/scripts/smoke-remote-release.sh runs the Linux-built
# daemon (start, trusted Unix RPC, capabilities). Exit 1 on any difference.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2
  exit 2
fi
LINUX_DIR="$(cd "$1" && pwd)" MAC_DIR="$(cd "$2" && pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$(uname -m)" in arm64) TARGET=aarch64-apple-darwin ;; x86_64) TARGET=x86_64-apple-darwin ;; *) exit 2 ;; esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macos-cross-runtime.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
status=0

# smoke-remote-release.sh needs timeout(1), which macOS lacks.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/timeout" <<'EOF'
#!/usr/bin/env bash
# timeout [--kill-after=D] DURATION CMD...: GNU timeout subset for the smoke.
[[ "$1" == --kill-after=* ]] && shift
seconds="${1%s}"; shift
exec perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$seconds" "$@"
EOF
chmod +x "$WORK/bin/timeout"
export PATH="$WORK/bin:$PATH"

load_info() { # <binary>: platform/minos and dylib install names, one per line
  otool -l "$1" | awk '/cmd LC_BUILD_VERSION/{b=1} b&&/platform|minos/{print $1, $2} /cmd LC_VERSION_MIN_MACOSX/{v=1} v&&/ version /{print "version_min", $2; v=0}' | sort -u
  otool -L "$1" | tail -n +2 | awk '{print $1}' | sort
}
version_of() { # <name> <binary>
  case "$1" in
    cmux-tui|cmux-tui-hook|cmux-tui-acpmux|cmux-relay|chatmux-relay) "$2" --version 2>&1 || true ;;
    *) "$2" version 2>&1 || true ;;
  esac
}

for name in cmux-tui cmux-tui-hook cmux-tui-acpmux cmux-relay chatmux-relay \
            cmux-tui-app-host cmux-tui-browser-host cmux-tui-cloud-server; do
  linux="$LINUX_DIR/$name-$TARGET" mac="$MAC_DIR/$name-$TARGET"
  if [[ ! -f "$linux" || ! -f "$mac" ]]; then
    echo "SKIP $name-$TARGET: missing $( [[ -f "$linux" ]] || echo linux ) $( [[ -f "$mac" ]] || echo mac )"
    continue
  fi
  cp "$linux" "$WORK/$name.linux" && cp "$mac" "$WORK/$name.mac" && chmod +x "$WORK/$name".*
  problems=()
  [[ "$(load_info "$WORK/$name.linux")" == "$(load_info "$WORK/$name.mac")" ]] || problems+=("load commands or dylibs differ")
  codesign --verify --strict "$WORK/$name.linux" 2>/dev/null || problems+=("signature invalid")
  # The stamps are the same source commit, so the version text must match.
  if [[ "$name" != cmux-tui-app-host && "$name" != cmux-tui-cloud-server ]] \
     && [[ "$(version_of "$name" "$WORK/$name.linux")" != "$(version_of "$name" "$WORK/$name.mac")" ]]; then
    problems+=("version output differs")
  fi
  if ((${#problems[@]})); then
    echo "FAIL $name-$TARGET: ${problems[*]}"; status=1
  else
    echo "PASS $name-$TARGET: runs; minos, dylibs and signature match the Mac build"
  fi
done

if [[ -f "$LINUX_DIR/cmux-tui-$TARGET" ]]; then
  mkdir -p "$WORK/smoke" && cp "$LINUX_DIR/cmux-tui-$TARGET" "$WORK/smoke/cmux-tui" && chmod +x "$WORK/smoke/cmux-tui"
  if TMPDIR=/tmp "$ROOT/cmux-tui/scripts/smoke-remote-release.sh" "$WORK/smoke/cmux-tui" > "$WORK/smoke.log" 2>&1; then
    echo "PASS smoke-remote-release.sh with the Linux-built cmux-tui-$TARGET"
  else
    echo "FAIL smoke-remote-release.sh with the Linux-built cmux-tui-$TARGET:"; tail -20 "$WORK/smoke.log"; status=1
  fi
fi
exit $status
