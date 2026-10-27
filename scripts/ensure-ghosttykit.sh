#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

usage() {
  cat <<'USAGE'
Usage: scripts/ensure-ghosttykit.sh [--variant fast|safe]

  --variant fast  (default) GhosttyKit.xcframework from the ghostty submodule,
                  -Doptimize=ReleaseFast, linked at ./GhosttyKit.xcframework.
  --variant safe  The ReleaseSafe lab libghostty: GhosttyNextKit.xcframework
                  from the commit and flavor that Packages/Shared/CmuxGhosttyKit/
                  Package.swift pins (ghostty-next must be checked out there),
                  built with that flavor's flags (ghostty-next
                  next/build-xcframework.sh) but -Doptimize=ReleaseSafe,
                  under its own cache key, linked at
                  Packages/Shared/CmuxGhosttyKit/Variants/safe/. The package
                  uses it only when CMUX_GHOSTTYKIT_VARIANT=safe, which
                  scripts/reload.sh sets for --config asan|tsan|ubsan alone.
                  Never for a shipped build.
USAGE
}

VARIANT="fast"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      [[ $# -ge 2 ]] || { echo "error: --variant needs fast or safe" >&2; exit 2; }
      VARIANT="$2"
      shift 2
      ;;
    --variant=*) VARIANT="${1#--variant=}"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
case "$VARIANT" in
  fast | safe) ;;
  *) echo "error: --variant takes fast or safe (got '$VARIANT')" >&2; exit 2 ;;
esac

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

# Prints the hash of a submodule's uncommitted changes and untracked files, or
# nothing when its checkout is clean.
submodule_dirty_hash() {
  local submodule="$1" head untracked path
  head="$(git -C "$submodule" rev-parse HEAD)"
  untracked="$(git -C "$submodule" ls-files --others --exclude-standard)"
  if git -C "$submodule" diff --quiet --ignore-submodules=all HEAD -- && [[ -z "$untracked" ]]; then
    return 0
  fi
  {
    printf 'head=%s\n' "$head"
    git -C "$submodule" diff --binary HEAD -- .
    if [[ -n "$untracked" ]]; then
      printf '\n--untracked--\n'
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf 'path=%s\n' "$path"
        hash_file "$PROJECT_DIR/$submodule/$path"
      done <<< "$untracked"
    fi
  } | hash_stdin
}

lookup_pinned_ghosttykit_sha256() {
  local ghostty_sha="$1"
  local checksums_file="$2"
  awk -v sha="$ghostty_sha" '
    $1 == sha {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$checksums_file"
}

validate_bridge_header() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
required = '#include "ghostty/include/ghostty.h"'
if required not in text:
    raise SystemExit(1)
PY
}

CACHE_ROOT="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}"

# One lock file per build key, so concurrent setups build a key once. The lock
# is flock(2) on a descriptor this shell keeps open, so the kernel releases it
# when the holder exits, crashed or not, and a live holder is never taken over
# however long its build runs.
print_sanitized_lock_error() {
  local lock_file="$1" message="$2" line
  [[ -n "$message" ]] || return 0
  while IFS= read -r line; do
    line="${line//$lock_file/<GhosttyKit cache lock>}"
    line="${line//$CACHE_ROOT/<GhosttyKit cache>}"
    if [[ -n "${HOME:-}" ]]; then
      line="${line//$HOME/~}"
    fi
    printf '  %s\n' "$line" >&2
  done <<< "$message"
}
# Takes the exclusive flock of lock file $2 on descriptor $1 (8 or 9) until this
# process exits; $3 names what it guards in the waiting message.
acquire_lock() {
  local fd="$1" lock_file="$2" label="$3" open_err
  if ! open_err="$( { : >>"$lock_file"; } 2>&1 )"; then
    echo "error: could not create the GhosttyKit cache lock." >&2
    print_sanitized_lock_error "$lock_file" "$open_err"
    echo "Check that the GhosttyKit cache directory is writable." >&2
    exit 1
  fi
  case "$fd" in
    8) exec 8>>"$lock_file" ;;
    9) exec 9>>"$lock_file" ;;
    *) echo "error: acquire_lock takes descriptor 8 or 9, not '$fd'" >&2; exit 1 ;;
  esac
  # The flock belongs to the open file, which this shell keeps after python exits.
  python3 - "$fd" "$label" <<'PY'
import fcntl
import sys

fd = int(sys.argv[1])
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print(f"==> Waiting for the GhosttyKit lock for {sys.argv[2]} (another setup holds it)...", flush=True)
    fcntl.flock(fd, fcntl.LOCK_EX)
PY
}
acquire_cache_lock() {
  acquire_lock 9 "$CACHE_ROOT/$1.flock" "$1"
}

# Refreshes the ranlib index of every macOS static archive under $1: Xcode 26 can
# fail to resolve symbols from a universal static archive until its index is
# refreshed after reuse or copy.
refresh_macos_archive_indexes() {
  local archive ranlib=""
  for archive in "$1"/macos-*/*.a; do
    [[ -f "$archive" ]] || continue
    if [[ -z "$ranlib" ]]; then
      echo "==> Refreshing libghostty archive index..."
      if ! command -v xcrun >/dev/null 2>&1; then
        echo "error: xcrun is required to refresh libghostty archive index." >&2
        exit 1
      fi
      if ! ranlib="$(xcrun --find ranlib 2>/dev/null)"; then
        echo "error: could not locate ranlib via xcrun." >&2
        exit 1
      fi
    fi
    "$ranlib" "$archive"
  done
}

# The ReleaseSafe lab variant (chrome-parity p10-stability-165). The cmux-next
# app links GhosttyNextKit (Packages/Shared/CmuxGhosttyKit), the ReleaseFast
# build of the ghostty-next gitlink. Sanitizer lab apps link this one: the same
# commit and flavor flags with -Doptimize=ReleaseSafe only, so Zig's bounds,
# overflow, null and unreachable checks trap inside libghostty, as Chromium's
# is_asan release bots keep their checks on (docs/asan.md). Its cache key names
# the variant, so it never replaces a ReleaseFast build.
NEXT_DIR="$PROJECT_DIR/ghostty-next"
SAFE_VARIANT_LINK="$PROJECT_DIR/Packages/Shared/CmuxGhosttyKit/Variants/safe/GhosttyNextKit.xcframework"
SAFE_VARIANT_REVISION="v1"
SAFE_TMP_DIR=""
trap '[[ -z "$SAFE_TMP_DIR" ]] || rm -rf "$SAFE_TMP_DIR"' EXIT

# Prints the flags=( ... ) of ghostty-next's next/build-xcframework.sh (the
# pinned flavor's `zig build` flags), one per line, -Doptimize=ReleaseSafe in
# place of its -Doptimize=ReleaseFast.
safe_variant_flags() {
  local script="$1" flag optimize=0 out=""
  while IFS= read -r flag; do
    case "$flag" in
      -Doptimize=ReleaseFast) flag="-Doptimize=ReleaseSafe"; optimize=$((optimize + 1)) ;;
      -Doptimize=*)
        echo "error: $script builds $flag, not -Doptimize=ReleaseFast; review the safe variant" >&2
        return 1
        ;;
      -D[a-z]*=*) ;;
      *)
        echo "error: unexpected zig build flag '$flag' in $script" >&2
        return 1
        ;;
    esac
    out+="$flag"$'\n'
  done < <(awk '/^flags=\(/ { inside = 1; next } inside && /^\)/ { exit } inside { for (i = 1; i <= NF; i++) print $i }' "$script")
  if (( optimize != 1 )); then
    echo "error: $script has no single -Doptimize=ReleaseFast flag" >&2
    return 1
  fi
  printf '%s' "$out"
}

build_safe_variant() {
  local cached="$1" zig_version="$2" flags_text="$3" flag zig built tree_lock
  local -a flags=()
  while IFS= read -r flag; do
    [[ -n "$flag" ]] && flags+=("$flag")
  done <<< "$flags_text"
  # zig build writes macos/GhosttyNextKit.xcframework in this checkout's
  # ghostty-next, whatever the key: one build per source tree at a time.
  tree_lock="$CACHE_ROOT/.ghostty-next-tree-$(printf '%s' "$NEXT_DIR" | hash_stdin).flock"
  acquire_lock 8 "$tree_lock" "the ghostty-next build tree"
  zig="$("$NEXT_DIR/next/install-zig.sh" "$CACHE_ROOT/zig" | tail -n 1)"
  if [[ ! -x "$zig" || "$("$zig" version)" != "$zig_version" ]]; then
    echo "error: ghostty-next's next/install-zig.sh gave no Zig $zig_version" >&2
    exit 1
  fi
  if [[ -x "$SCRIPT_DIR/ensure-metal-toolchain.sh" ]]; then
    "$SCRIPT_DIR/ensure-metal-toolchain.sh"
  fi
  SAFE_TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttynextkit-safe-tmp.XXXXXX")"
  built="$NEXT_DIR/macos/GhosttyNextKit.xcframework"
  rm -rf "$built"
  echo "==> Building ReleaseSafe GhosttyNextKit.xcframework: zig build ${flags[*]}"
  (
    cd "$NEXT_DIR"
    # build.zig runs `zig env`, so the pinned Zig leads PATH; archive members
    # carry no timestamps (as next/build-xcframework.sh builds). The install
    # prefix is private: the xcframework build installs share/{ghostty,terminfo},
    # and scripts/cmux-next/bundle-ghostty-resources.sh bundles
    # ghostty-next/zig-out/share in place of Resources/ghostty when it exists.
    PATH="$(dirname "$zig"):$PATH"
    export PATH ZERO_AR_DATE=1
    "$zig" build "${flags[@]}" --prefix "$SAFE_TMP_DIR/zig-out" --summary failures
  )
  if [[ ! -d "$built" ]]; then
    echo "error: zig build made no $built" >&2
    exit 1
  fi
  mv "$built" "$SAFE_TMP_DIR/GhosttyNextKit.xcframework"
  mkdir -p "$(dirname "$cached")"
  # The key lock is held and $cached is absent, so this rename publishes the
  # complete build at once and replaces nothing another reload links.
  mv "$SAFE_TMP_DIR/GhosttyNextKit.xcframework" "$cached"
  rm -rf "$SAFE_TMP_DIR"
  SAFE_TMP_DIR=""
  echo "==> Cached ReleaseSafe GhosttyNextKit.xcframework at $cached"
}

# Prints "<commit> <flavor>" of the GhosttyNextKit binaryTarget url that
# Packages/Shared/CmuxGhosttyKit/Package.swift pins: the libghostty the fast
# build ships.
pinned_ghosttynextkit() {
  local package="$PROJECT_DIR/Packages/Shared/CmuxGhosttyKit/Package.swift" pins
  pins="$(sed -n 's|.*/releases/download/xcframework-\([0-9a-f]\{40\}\)-\([A-Za-z0-9._-]*\)/GhosttyNextKit\.xcframework\.zip".*|\1 \2|p' "$package" 2>/dev/null || true)"
  if [[ -z "$pins" || "$pins" == *$'\n'* ]]; then
    echo "error: ${package#"$PROJECT_DIR"/} pins no single GhosttyNextKit xcframework-<commit>-<flavor> url" >&2
    return 1
  fi
  printf '%s\n' "$pins"
}

ensure_safe_variant() {
  local toolchain="$NEXT_DIR/next/toolchain.env" build_script="$NEXT_DIR/next/build-xcframework.sh"
  if [[ ! -f "$NEXT_DIR/build.zig" || ! -f "$toolchain" || ! -f "$build_script" || ! -x "$NEXT_DIR/next/install-zig.sh" ]]; then
    echo "error: the ghostty-next submodule is missing. Run: git submodule update --init ghostty-next" >&2
    exit 1
  fi
  local next_sha flavor zig_version flags_text key dirty cached pins pin_sha pin_flavor
  pins="$(pinned_ghosttynextkit)" || exit 1
  read -r pin_sha pin_flavor <<< "$pins"
  next_sha="$(git -C "$NEXT_DIR" rev-parse HEAD)"
  flavor="$(sed -n 's/^GHOSTTYKIT_FLAVOR=//p' "$toolchain")"
  zig_version="$(sed -n 's/^ZIG_VERSION=//p' "$toolchain")"
  if [[ -z "$flavor" || -z "$zig_version" ]]; then
    echo "error: ghostty-next's next/toolchain.env names no GHOSTTYKIT_FLAVOR or ZIG_VERSION" >&2
    exit 1
  fi
  # The lab build is the shipped commit and flavor with ReleaseSafe only; a
  # checkout at another commit would test code that does not ship.
  if [[ "$next_sha" != "$pin_sha" ]]; then
    echo "error: ghostty-next is checked out at $next_sha, but Package.swift's GhosttyNextKit pin is $pin_sha." >&2
    echo "The safe variant builds the pinned commit only. Run: git submodule update ghostty-next" >&2
    exit 1
  fi
  if [[ "$flavor" != "$pin_flavor" ]]; then
    echo "error: ghostty-next's next/toolchain.env has GHOSTTYKIT_FLAVOR=$flavor, but Package.swift's GhosttyNextKit pin is flavor $pin_flavor." >&2
    exit 1
  fi
  flags_text="$(safe_variant_flags "$build_script")" || exit 1
  key="next-${next_sha}-${flavor}-releasesafe-${SAFE_VARIANT_REVISION}"
  dirty="$(submodule_dirty_hash ghostty-next)"
  if [[ -n "$dirty" ]]; then
    key="${key}-dirty-${dirty}"
  fi
  cached="$CACHE_ROOT/$key/GhosttyNextKit.xcframework"
  mkdir -p "$CACHE_ROOT"
  echo "==> GhosttyNextKit safe variant build key: $key"
  acquire_cache_lock "$key"
  if [[ -d "$cached" ]]; then
    echo "==> Reusing cached ReleaseSafe GhosttyNextKit.xcframework"
  else
    build_safe_variant "$cached" "$zig_version" "$flags_text"
  fi
  refresh_macos_archive_indexes "$cached"
  mkdir -p "$(dirname "$SAFE_VARIANT_LINK")"
  ln -sfn "$cached" "$SAFE_VARIANT_LINK"
  echo "==> Linked the safe variant at ${SAFE_VARIANT_LINK#"$PROJECT_DIR"/} (CMUX_GHOSTTYKIT_VARIANT=safe selects it)"
}

if [[ "$VARIANT" == safe ]]; then
  ensure_safe_variant
  exit 0
fi

if [[ ! -d "$PROJECT_DIR/ghostty" ]]; then
  echo "error: ghostty submodule is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/ghostty-zig-version.sh"

if [[ ! -f "$PROJECT_DIR/ghostty/include/ghostty.h" ]]; then
  echo "error: ghostty/include/ghostty.h is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! validate_bridge_header "$PROJECT_DIR/ghostty.h"; then
  echo "error: ghostty.h no longer points at ghostty/include/ghostty.h." >&2
  echo "Restore the bridge header so Xcode uses Ghostty's canonical C API." >&2
  exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
GHOSTTYKIT_CRASH_REPORT_SUBDIR="${CMUX_GHOSTTYKIT_CRASH_REPORT_SUBDIR:-cmux/crash}"
# cmux owns process-wide crash capture through Sentry Cocoa. Linking Ghostty's
# native Sentry as well creates a second global crash handler and starts its
# environment-reading init thread during Ghostty locale mutation.
GHOSTTYKIT_BUILD_FLAVOR="crashsubdir-$(printf '%s' "$GHOSTTYKIT_CRASH_REPORT_SUBDIR" | tr '/=' '--')-sentry-off-noi18n-v2"
GHOSTTY_CLEAN_KEY="${GHOSTTY_SHA}-${GHOSTTYKIT_BUILD_FLAVOR}"
GHOSTTY_KEY="$GHOSTTY_CLEAN_KEY"
DIRTY_HASH="$(submodule_dirty_hash ghostty)"
if [[ -n "$DIRTY_HASH" ]]; then
  GHOSTTY_KEY="${GHOSTTY_CLEAN_KEY}-dirty-${DIRTY_HASH}"
fi

CACHE_DIR="$CACHE_ROOT/$GHOSTTY_KEY"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_KEY_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_state_key"
LEGACY_LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
GHOSTTYKIT_CHECKSUMS_FILE="${CMUX_GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
GHOSTTYKIT_ARCHIVE_VALIDATOR="${CMUX_GHOSTTYKIT_ARCHIVE_VALIDATOR:-$SCRIPT_DIR/validate-xcframework-archive.py}"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty build key: $GHOSTTY_KEY"
acquire_cache_lock "$GHOSTTY_KEY"

try_fetch_prebuilt_xcframework() {
  # Only attempt when Ghostty submodule is clean — dirty trees won't match any
  # published release. Opt-out via CMUX_GHOSTTYKIT_NO_PREBUILT=1.
  #
  # Trust model: only install prebuilt artifacts whose SHA256 is pinned in the
  # reviewed checksum manifest for the current ghostty submodule commit.
  # Unpinned or mismatched artifacts fall back to a local ReleaseFast build.
  if [[ "$GHOSTTY_KEY" != "$GHOSTTY_CLEAN_KEY" ]]; then
    return 1
  fi
  if [[ "${CMUX_GHOSTTYKIT_NO_PREBUILT:-0}" == "1" ]]; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  local url="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_CLEAN_KEY}/GhosttyKit.xcframework.tar.gz"
  if [[ ! -f "$GHOSTTYKIT_CHECKSUMS_FILE" ]]; then
    echo "==> Missing GhosttyKit checksum manifest; falling back to local build." >&2
    return 1
  fi

  local expected_sha
  if ! expected_sha="$(lookup_pinned_ghosttykit_sha256 "$GHOSTTY_SHA" "$GHOSTTYKIT_CHECKSUMS_FILE" 2>/dev/null)"; then
    echo "==> No pinned GhosttyKit checksum for ${GHOSTTY_SHA:0:12}; falling back to local build." >&2
    return 1
  fi

  local tmp_dir tmp_tar tmp_extract actual_sha
  tmp_dir="$(mktemp -d "$CACHE_ROOT/.ghosttykit-prebuilt.XXXXXX")"
  tmp_tar="$tmp_dir/GhosttyKit.xcframework.tar.gz"
  tmp_extract="$tmp_dir/extract"
  mkdir -p "$tmp_extract"
  echo "==> Fetching prebuilt GhosttyKit.xcframework for ${GHOSTTY_SHA:0:12}..."
  if ! curl -fSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 --retry-all-errors -o "$tmp_tar" "$url"; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt xcframework not available; falling back to local build."
    return 1
  fi

  actual_sha="$(hash_file "$tmp_tar")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt xcframework checksum mismatch; falling back to local build." >&2
    echo "    expected: $expected_sha" >&2
    echo "    actual:   $actual_sha" >&2
    return 1
  fi

  if ! python3 "$GHOSTTYKIT_ARCHIVE_VALIDATOR" "$tmp_tar"; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt xcframework archive failed validation; falling back to local build." >&2
    return 1
  fi

  if ! tar --no-same-owner -xzf "$tmp_tar" -C "$tmp_extract"; then
    rm -rf "$tmp_dir"
    echo "==> Failed to extract verified prebuilt xcframework; falling back to local build." >&2
    return 1
  fi

  local extracted="$tmp_extract/GhosttyKit.xcframework"
  if [[ ! -d "$extracted" ]]; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt archive did not contain GhosttyKit.xcframework; falling back." >&2
    return 1
  fi

  mkdir -p "$(dirname "$LOCAL_XCFRAMEWORK")"
  rm -rf "$LOCAL_XCFRAMEWORK"
  mv "$extracted" "$LOCAL_XCFRAMEWORK"
  rm -rf "$tmp_dir"
  echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
  echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
  return 0
}

if [[ -d "$CACHE_XCFRAMEWORK" ]]; then
  echo "==> Reusing cached GhosttyKit.xcframework"
else
  LOCAL_KEY=""
  if [[ -f "$LOCAL_KEY_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LOCAL_KEY_STAMP")"
  elif [[ -f "$LEGACY_LOCAL_SHA_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LEGACY_LOCAL_SHA_STAMP")"
  fi

  if [[ -d "$LOCAL_XCFRAMEWORK" && "$LOCAL_KEY" == "$GHOSTTY_KEY" ]]; then
    echo "==> Seeding cache from existing local GhosttyKit.xcframework (build key matches)"
  elif try_fetch_prebuilt_xcframework; then
    echo "==> Seeding cache from prebuilt GhosttyKit.xcframework"
  else
    ghostty_require_compatible_zig "$PROJECT_DIR"
    echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
    if [[ -x "$SCRIPT_DIR/ensure-metal-toolchain.sh" ]]; then
      "$SCRIPT_DIR/ensure-metal-toolchain.sh"
    fi
    (
      cd ghostty
      # -Di18n=false: compiling Ghostty's .po catalogs needs gettext's
      # msgfmt, which not every builder has, and cmux never bundles the
      # resulting .mo files (they only install into Ghostty's own app
      # bundle, skipped by -Demit-macos-app=false). Runtime lookups are
      # comptime-gated to return the msgid, which is what cmux shipped
      # all along.
      zig build \
        -Dcrash-report-subdir="$GHOSTTYKIT_CRASH_REPORT_SUBDIR" \
        -Dsentry=false \
        -Di18n=false \
        -Demit-macos-app=false \
        -Demit-xcframework=true \
        -Dxcframework-target=universal \
        -Doptimize=ReleaseFast
    )
    echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
    echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
  fi

  if [[ ! -d "$LOCAL_XCFRAMEWORK" ]]; then
    echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK" >&2
    exit 1
  fi

  TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
  mkdir -p "$CACHE_DIR"
  cp -R "$LOCAL_XCFRAMEWORK" "$TMP_DIR/GhosttyKit.xcframework"
  rm -rf "$CACHE_XCFRAMEWORK"
  mv "$TMP_DIR/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
  rmdir "$TMP_DIR"
  echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK"
fi

refresh_macos_archive_indexes "$CACHE_XCFRAMEWORK"

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework
