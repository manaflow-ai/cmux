#!/usr/bin/env bash
set -euo pipefail

CMUX_CUA_REPO_URL="${CMUX_CUA_REPO_URL:-https://github.com/manaflow-ai/cmux-cua.git}"
CMUX_CUA_PINNED_SHA="d39b377de51eec5a4247ab7b86ce5884bed05ff8"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT=""
ARCHS_RAW=""
CACHE_DIR="${CMUX_CUA_CACHE_DIR:-${HOME:-/tmp}/Library/Caches/cmux/cua-driver}"
VERIFY_DOCTOR=1

usage() {
  cat <<'USAGE' >&2
usage: scripts/build-cua-driver.sh --output <path> [options]

Options:
  --archs "<archs>"     architectures to build (default: "arm64 x86_64")
  --cache-dir <path>    clone/build cache dir (default: ~/Library/Caches/cmux/cua-driver)
  --skip-doctor-verify  skip the post-build `doctor --json` probe
  -h, --help            show this help

Environment:
  CMUX_CUA_SRC          existing cmux-cua checkout to read instead of cloning/fetching
  CMUX_CUA_CACHE_DIR    default cache dir override
  CMUX_CUA_REPO_URL     repo URL override, defaults to manaflow-ai/cmux-cua
USAGE
}

while (($#)); do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --archs)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHS_RAW="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      CACHE_DIR="$2"
      shift 2
      ;;
    --skip-doctor-verify)
      VERIFY_DOCTOR=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  echo "error: --output is required" >&2
  usage
  exit 2
fi

if [[ -z "$ARCHS_RAW" ]]; then
  ARCHS_RAW="arm64 x86_64"
fi

read -r -a ARCHS <<<"$ARCHS_RAW"
if ((${#ARCHS[@]} == 0)); then
  echo "error: no architectures requested" >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required; run scripts/install-rust-ci.sh in CI" >&2; exit 1; }

mkdir -p "$CACHE_DIR"

if [[ -n "${CMUX_CUA_SRC:-}" ]]; then
  SRC_ROOT="$(cd "$CMUX_CUA_SRC" && pwd)"
  if [[ ! -d "$SRC_ROOT/.git" ]]; then
    echo "error: CMUX_CUA_SRC is not a git checkout: $SRC_ROOT" >&2
    exit 1
  fi
else
  SRC_ROOT="$CACHE_DIR/cmux-cua"
  if [[ ! -d "$SRC_ROOT/.git" ]]; then
    git clone "$CMUX_CUA_REPO_URL" "$SRC_ROOT"
  fi
  git -C "$SRC_ROOT" fetch --quiet origin "$CMUX_CUA_PINNED_SHA"
  git -C "$SRC_ROOT" checkout --quiet --detach "$CMUX_CUA_PINNED_SHA"
fi

ACTUAL_SHA="$(git -C "$SRC_ROOT" rev-parse HEAD)"
if [[ "$ACTUAL_SHA" != "$CMUX_CUA_PINNED_SHA" ]]; then
  echo "error: cmux-cua checkout is at $ACTUAL_SHA, expected $CMUX_CUA_PINNED_SHA" >&2
  exit 1
fi

CARGO_ROOT="$SRC_ROOT/libs/cua-driver/rust"
if [[ ! -f "$CARGO_ROOT/Cargo.toml" ]]; then
  echo "error: cua-driver Cargo workspace not found at $CARGO_ROOT" >&2
  exit 1
fi

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cua-driver.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR_BUILD"
}
trap cleanup EXIT

mkdir -p "$(dirname "$OUTPUT")"

ensure_rust_target() {
  local target="$1"
  if command -v rustup >/dev/null 2>&1; then
    if ! rustup target list --installed | grep -qx "$target"; then
      rustup target add "$target"
    fi
  fi
}

BUILT=()
for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|aarch64)
      arch="arm64"
      target="aarch64-apple-darwin"
      ;;
    x86_64|amd64)
      arch="x86_64"
      target="x86_64-apple-darwin"
      ;;
    *)
      echo "error: unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac

  ensure_rust_target "$target"
  target_dir="$CACHE_DIR/target-$target"
  CARGO_TARGET_DIR="$target_dir" \
    cargo build --manifest-path "$CARGO_ROOT/Cargo.toml" --locked -p cua-driver --release --target "$target"
  arch_output="$TMPDIR_BUILD/cmux-cua-driver-$arch"
  cp "$target_dir/$target/release/cua-driver" "$arch_output"
  BUILT+=("$arch_output")
done

if ((${#BUILT[@]} == 1)); then
  cp "${BUILT[0]}" "$OUTPUT"
else
  /usr/bin/lipo -create "${BUILT[@]}" -output "$OUTPUT"
fi
chmod 0755 "$OUTPUT"

/usr/bin/codesign --force --sign - --timestamp=none "$OUTPUT"
/usr/bin/codesign --verify --strict "$OUTPUT"
"$OUTPUT" --version >/dev/null
if [[ "$VERIFY_DOCTOR" -eq 1 ]]; then
  verify_home="$TMPDIR_BUILD/home"
  mkdir -p "$verify_home"
  HOME="$verify_home" \
    CUA_DRIVER_RS_TELEMETRY_ENABLED=false \
    "$OUTPUT" doctor --json >/dev/null
fi
