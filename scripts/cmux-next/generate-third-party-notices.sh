#!/usr/bin/env bash
# Generates THIRD_PARTY_LICENSES.md for the cmux-next app bundle.
#
#   generate-third-party-notices.sh [--check] [--tui-source pin|tree]
#                                   [--cargo-trees DIR [--write-cargo-trees]]
#
#   --check            fail when THIRD_PARTY_LICENSES.md (or REVIEW.md) is stale
#   --tui-source pin   (default) the cmux-tui pin's crates, as release and RC
#                      builds bundle; this is the committed file
#   --tui-source tree  this checkout's crates, as dogfood and nightly builds
#                      bundle (pin-cmux-tui.sh tree mode); first-party sources
#                      point at this checkout's HEAD commit; REVIEW.md is not
#                      touched. Nightly-next runs this before its Release build.
#   --cargo-trees DIR  exact closures: DIR/<section>.txt is `cargo tree` output
#                      (rust_notices.py --cargo-tree); a section without a file
#                      keeps the conservative lock closure
#   --write-cargo-trees  first write DIR/<section>.txt with cargo (needs
#                      CMUX_NOTICES_ALLOW_CARGO=1: CI runners and Testboxes only,
#                      never a maintainer's Mac)
#
# The file is the hand-written input (scripts/cmux-next/notices/hand-written.md,
# owned by the license review, copied byte for byte with section markers), one
# generated crate list per bundled Rust binary (cmux-tui/build-support/notices/
# rust_notices.py; union of aarch64 and x86_64 macOS closures), and one shared
# block that prints each license text once, and the Ghostty themes section
# (ghostty_themes_notice.py, for Resources/ghostty/themes):
#
#   rust-cmux-cli           bin/cmux and bin/cmux-tui-ssh/*  cmux-tui/Cargo.lock
#   rust-cmux-app-host      bin/cmux-app-host                cmux-tui/Cargo.lock
#   rust-cmux-browser-host  bin/cmux-browser-host            cmux-tui/Cargo.lock
#   rust-cmux-cloud         bin/cmux-cloud                   first-party-apps/cloud/server
#   rust-cmux-diff-sidecar  bin/cmux-diff-sidecar            Native/DiffSidecar/Cargo.lock (this tree)
#   rust-iroh-ffi           Iroh.framework                   manaflow-ai/iroh-ffi at the Package.resolved revision
#
# In pin mode first-party crates point at the permanent tag
# cmux-tui-src-<pin, 11 characters>, which must exist.
#
# Crate sources come from crates.io and git into a CARGO_HOME-shaped cache
# (CMUX_NOTICES_CACHE, default ~/.cache/cmux-notices; fetch_crates.py checks
# every .crate against its Cargo.lock sha256). The first run needs the network.
# scripts/verify-app-bundle-licenses.sh checks the bundled result against
# scripts/cmux-next/notices/bundle-map.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NOTICES="$ROOT/cmux-tui/build-support/notices"
CACHE="${CMUX_NOTICES_CACHE:-$HOME/.cache/cmux-notices}"
CHECK=0 TUI_SOURCE=pin TREES="" WRITE_TREES=0
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1 ;;
    --tui-source) TUI_SOURCE="${2:?}"; shift ;;
    --cargo-trees) TREES="${2:?}"; shift ;;
    --write-cargo-trees) WRITE_TREES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ "$TUI_SOURCE" == pin || "$TUI_SOURCE" == tree ]] || { echo "error: --tui-source is pin or tree" >&2; exit 2; }
[[ "$WRITE_TREES" == 0 || -n "$TREES" ]] || { echo "error: --write-cargo-trees needs --cargo-trees DIR" >&2; exit 2; }
if [[ "$WRITE_TREES" == 1 && "${CMUX_NOTICES_ALLOW_CARGO:-}" != 1 ]]; then
  echo "error: --write-cargo-trees runs cargo; set CMUX_NOTICES_ALLOW_CARGO=1 on a CI runner or Testbox (never on a maintainer's Mac)" >&2
  exit 2
fi
if [[ "$TUI_SOURCE" == tree && "$CHECK" == 1 ]]; then
  echo "error: --check compares the committed file, which is pin mode" >&2
  exit 2
fi

iroh_rev="$(python3 -c 'import json, sys
pins = [p for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "iroh-ffi"]
print(pins[0]["state"]["revision"])' "$ROOT/Packages/macOS/CmuxNext/Package.resolved")"
[[ "$iroh_rev" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no iroh-ffi revision in Packages/macOS/CmuxNext/Package.resolved" >&2; exit 1; }

mkdir -p "$CACHE"
if [[ "$TUI_SOURCE" == pin ]]; then
  pin="$(sed -n 's/^commit=//p' "$ROOT/scripts/cmux-next/cmux-tui.pin")"
  [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no commit= line in scripts/cmux-next/cmux-tui.pin" >&2; exit 1; }
  ref="cmux-tui-src-${pin:0:11}"
  if ! git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$ref" >/dev/null; then
    echo "error: source tag $ref (the cmux-tui pin) does not exist on origin; first-party crates must point at a permanent tag" >&2
    exit 1
  fi
  tui_src="$CACHE/cmux-src-$pin"
  if [[ ! -d "$tui_src" ]]; then
    git -C "$ROOT" cat-file -e "$pin^{commit}" 2>/dev/null || git -C "$ROOT" fetch --quiet origin "$pin"
    rm -rf "$tui_src.partial" && mkdir -p "$tui_src.partial"
    git -C "$ROOT" archive "$pin" cmux-tui first-party-apps/cloud/server | tar -x -C "$tui_src.partial"
    mv "$tui_src.partial" "$tui_src"
  fi
  tui_label="at the cmux-tui pin ${pin:0:11}"
else
  ref="$(git -C "$ROOT" rev-parse HEAD)"
  tui_src="$ROOT"
  tui_label="at ${ref:0:11}"
fi

iroh_src="$CACHE/iroh-ffi-$iroh_rev"
if [[ ! -d "$iroh_src" ]]; then
  rm -rf "$iroh_src.partial" && mkdir -p "$iroh_src.partial"
  git -C "$iroh_src.partial" init --quiet
  git -C "$iroh_src.partial" fetch --quiet --depth 1 https://github.com/manaflow-ai/iroh-ffi.git "$iroh_rev"
  git -C "$iroh_src.partial" checkout --quiet FETCH_HEAD
  [[ "$(git -C "$iroh_src.partial" rev-parse HEAD)" == "$iroh_rev" ]] || { echo "error: iroh-ffi checkout is not $iroh_rev" >&2; exit 1; }
  mv "$iroh_src.partial" "$iroh_src"
fi

if [[ "$WRITE_TREES" == 1 ]]; then
  mkdir -p "$TREES"
  cargo_tree() { # <section> <dir> <package>...
    local id="$1" dir="$2"
    shift 2
    local packages=()
    for p in "$@"; do packages+=(-p "$p"); done
    (cd "$dir" && cargo tree --locked -e normal,no-proc-macro \
      --target aarch64-apple-darwin --target x86_64-apple-darwin \
      --prefix none -f '{p}' "${packages[@]}") > "$TREES/$id.txt"
    echo "cargo tree $id: $(sort -u "$TREES/$id.txt" | wc -l | tr -d ' ') lines"
  }
  cargo_tree rust-cmux-cli "$tui_src/cmux-tui" cmux-tui acpmux
  cargo_tree rust-cmux-app-host "$tui_src/cmux-tui" cmux-app-host
  cargo_tree rust-cmux-browser-host "$tui_src/cmux-tui" cmux-browser-host
  cargo_tree rust-cmux-cloud "$tui_src/first-party-apps/cloud/server" cmux-cloud
  cargo_tree rust-cmux-diff-sidecar "$ROOT/Native/DiffSidecar" cmux-diff-sidecar
  cargo_tree rust-iroh-ffi "$iroh_src" iroh-ffi
fi

python3 "$NOTICES/fetch_crates.py" --cache "$CACHE" \
  --lock "$tui_src/cmux-tui/Cargo.lock" \
  --lock "$tui_src/first-party-apps/cloud/server/Cargo.lock" \
  --lock "$ROOT/Native/DiffSidecar/Cargo.lock" \
  --lock "$iroh_src/Cargo.lock"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

section() {
  local id="$1" title="$2" tree_arg=()
  shift 2
  if [[ -n "$TREES" && -f "$TREES/$id.txt" ]]; then tree_arg=(--cargo-tree "$TREES/$id.txt"); fi
  CARGO_HOME="$CACHE" python3 "$NOTICES/rust_notices.py" \
    --reviewed "$NOTICES/reviewed.json" \
    --first-party-license "$ROOT/cmux-tui/dist/npm/cmux/LICENSE" \
    --source-tag "$ref" \
    --target aarch64-apple-darwin --target x86_64-apple-darwin \
    --format markdown --section-id "$id" --title "$title" \
    "${tree_arg[@]}" --out "$work/$id.md" "$@"
}

section rust-cmux-cli "Rust crates: cmux CLI and daemon (bin/cmux)" \
  --lock "$tui_src/cmux-tui/Cargo.lock" --lock-label "cmux-tui/Cargo.lock $tui_label" \
  --root cmux-tui --root acpmux --workspace "$tui_src/cmux-tui" --repo-root "$tui_src" \
  --first-party 'cmux-tui/crates/*' --first-party 'cmux-tui/bindings/*'
section rust-cmux-app-host "Rust crates: app host (bin/cmux-app-host)" \
  --lock "$tui_src/cmux-tui/Cargo.lock" --lock-label "cmux-tui/Cargo.lock $tui_label" \
  --root cmux-app-host --workspace "$tui_src/cmux-tui" --repo-root "$tui_src" \
  --first-party 'cmux-tui/crates/*' --first-party 'cmux-tui/bindings/*'
section rust-cmux-browser-host "Rust crates: browser host (bin/cmux-browser-host)" \
  --lock "$tui_src/cmux-tui/Cargo.lock" --lock-label "cmux-tui/Cargo.lock $tui_label" \
  --root cmux-browser-host --workspace "$tui_src/cmux-tui" --repo-root "$tui_src" \
  --first-party 'cmux-tui/crates/*' --first-party 'cmux-tui/bindings/*'
section rust-cmux-cloud "Rust crates: Cloud app server (bin/cmux-cloud)" \
  --lock "$tui_src/first-party-apps/cloud/server/Cargo.lock" --lock-label "first-party-apps/cloud/server/Cargo.lock $tui_label" \
  --root cmux-cloud --workspace "$tui_src/first-party-apps/cloud/server" --workspace "$tui_src/cmux-tui" --repo-root "$tui_src" \
  --first-party 'first-party-apps/cloud/server' --first-party 'cmux-tui/crates/*' --first-party 'cmux-tui/bindings/*'
section rust-cmux-diff-sidecar "Rust crates: diff viewer sidecar (bin/cmux-diff-sidecar)" \
  --lock "$ROOT/Native/DiffSidecar/Cargo.lock" --lock-label "Native/DiffSidecar/Cargo.lock" \
  --root cmux-diff-sidecar --workspace "$ROOT/Native/DiffSidecar" --repo-root "$ROOT" \
  --first-party 'Native/DiffSidecar'
section rust-iroh-ffi "Rust crates: Iroh.framework (manaflow-ai/iroh-ffi)" \
  --lock "$iroh_src/Cargo.lock" --lock-label "manaflow-ai/iroh-ffi Cargo.lock at ${iroh_rev:0:11}" \
  --root iroh-ffi --workspace "$iroh_src" \
  --path-download "git+https://github.com/manaflow-ai/iroh-ffi.git@$iroh_rev"

python3 "$ROOT/scripts/cmux-next/notices/ghostty_themes_notice.py" --root "$ROOT" --out "$work/ghostty-themes.md"
compose=(python3 "$ROOT/scripts/cmux-next/notices/compose_notices.py"
  --hand-written "$ROOT/scripts/cmux-next/notices/hand-written.md"
  --section "$work/ghostty-themes.md"
  --section "$work/rust-cmux-cli.md" --section "$work/rust-cmux-app-host.md"
  --section "$work/rust-cmux-browser-host.md"
  --section "$work/rust-cmux-cloud.md" --section "$work/rust-cmux-diff-sidecar.md"
  --section "$work/rust-iroh-ffi.md"
  --out "$ROOT/THIRD_PARTY_LICENSES.md")
review=(python3 "$NOTICES/review_list.py" --cache "$CACHE"
  --lock "$tui_src/cmux-tui/Cargo.lock" --lock "$tui_src/first-party-apps/cloud/server/Cargo.lock"
  --lock "$ROOT/Native/DiffSidecar/Cargo.lock" --lock "$iroh_src/Cargo.lock")
if [[ "$TUI_SOURCE" == tree ]]; then
  "${compose[@]}"
  echo "wrote THIRD_PARTY_LICENSES.md for this tree (${ref:0:11}; $(wc -c < "$ROOT/THIRD_PARTY_LICENSES.md" | tr -d ' ') bytes)"
elif [[ "$CHECK" == 1 ]]; then
  "${review[@]}" --check
  "${compose[@]}" --check
  echo "THIRD_PARTY_LICENSES.md is current"
else
  "${review[@]}"
  "${compose[@]}"
  echo "wrote THIRD_PARTY_LICENSES.md ($(wc -c < "$ROOT/THIRD_PARTY_LICENSES.md" | tr -d ' ') bytes)"
fi
