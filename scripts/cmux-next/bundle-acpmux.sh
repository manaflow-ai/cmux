#!/usr/bin/env bash
# Xcode "Bundle acpmux" phase for cmux-next. The binary is built by CI or
# supplied from the commit-addressed fleet cache. This phase only copies it into
# the app, so an ordinary local Xcode build never starts a Cargo build.
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/acpmux"

# cmux-tui is the canonical multi-call binary. bundle-cmux-tui.sh installs it
# at bin/cmux and creates bin/cmux-tui and bin/acpmux as relative aliases.
# With no CMUX_NEXT_ACPMUX_BIN, keep that alias. With one, the app must launch
# that file: it is the Foundry daemon, and the alias would run the pinned cmux,
# which turns Foundry off for every call that is not `{on: true}`.
mkdir -p "$dest_dir"
rm -rf "$dest"
acpmux_mode="alias-to-cmux"
if [[ -n "${CMUX_NEXT_ACPMUX_BIN:-}" && -f "$CMUX_NEXT_ACPMUX_BIN" && ! -L "$CMUX_NEXT_ACPMUX_BIN" ]]; then
  cp -f "$CMUX_NEXT_ACPMUX_BIN" "$dest"
  chmod 755 "$dest"
  acpmux_mode="file"
else
  ln -s cmux "$dest"
fi

source_kind="$(awk -F= '$1 == "source" { print $2; exit }' "$dest_dir/cmux-tui.version" 2>/dev/null || true)"
commit="$(awk -F= '$1 == "commit" { print $2; exit }' "$dest_dir/cmux-tui.version" 2>/dev/null || true)"
[[ -n "$source_kind" ]] || source_kind="alias"
[[ -n "$commit" ]] || commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
src="${CMUX_NEXT_ACPMUX_BIN:-}"
if [[ -n "$src" && -f "$src.ref" ]]; then
  commit="$(awk -F= '$1 == "commit" { print $2; exit }' "$src.ref" 2>/dev/null || true)"
  source_kind="$(awk -F= '$1 == "source" { print $2; exit }' "$src.ref" 2>/dev/null || true)"
  [[ -n "$source_kind" ]] || source_kind="alias"
fi
cat > "$dest_dir/acpmux.version" <<EOF_VERSION
commit=$commit
source=$source_kind
mode=$acpmux_mode
EOF_VERSION
echo "bundled acpmux ($acpmux_mode, ${commit:-unknown})"
