#!/usr/bin/env bash
# Xcode "Bundle acpmux" phase for cmux-next. The binary is built by CI or
# supplied from the ref-addressed fleet cache. This phase only copies it into
# the app, so an ordinary local Xcode build never starts a Cargo build.
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/acpmux"

src="${CMUX_NEXT_ACPMUX_BIN:-}"
if [[ -z "$src" ]]; then
  src="$({ "$repo_root/scripts/cmux-next/build-acpmux.sh" --cached-only --print-path; } 2>/dev/null || true)"
fi
if [[ -z "$src" || ! -f "$src" ]]; then
  echo "error: no acpmux binary is available for this build. CI must run scripts/cmux-next/build-acpmux.sh and set CMUX_NEXT_ACPMUX_BIN; local reloads need the ref-addressed fleet cache." >&2
  exit 1
fi
[[ -x "$src" ]] || { echo "error: acpmux source is not executable: $src" >&2; exit 1; }

if ! /usr/bin/file -b "$src" | grep -q 'Mach-O'; then
  echo "error: acpmux source is not a Mach-O executable: $src" >&2
  exit 1
fi

# Xcode exports ARCHS for the target. A universal binary satisfies either
# slice; a thin binary must carry every architecture the app is being built for.
if command -v lipo >/dev/null 2>&1 && [[ -n "${ARCHS:-}" ]]; then
  actual_archs="$(lipo -archs "$src")"
  for expected in $ARCHS; do
    case " $actual_archs " in
      *" $expected "*) ;;
      *)
        echo "error: acpmux has architectures '$actual_archs', but the app needs '$ARCHS'" >&2
        exit 1
        ;;
    esac
  done
fi

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
mkdir -p "$dest_dir"
rm -f "$dest"
cp "$src" "$dest"
chmod 755 "$dest"

commit="$(awk -F= '$1 == "commit" { print $2; exit }' "$src.ref" 2>/dev/null || true)"
source_kind="$(awk -F= '$1 == "source" { print $2; exit }' "$src.ref" 2>/dev/null || true)"
if [[ -z "$commit" ]]; then
  commit="$(awk -F= '$1 == "commit" { print $2; exit }' "$repo_root/scripts/cmux-next/acpmux.ref")"
fi
[[ -n "$source_kind" ]] || source_kind="ci-or-cache"
actual_archs="$(command -v lipo >/dev/null 2>&1 && lipo -archs "$dest" || /usr/bin/file -b "$dest")"
cat > "$dest_dir/acpmux.version" <<EOF_VERSION
commit=$commit
source=$source_kind
sha256=$(sha256_of "$dest")
archs=$actual_archs
EOF_VERSION
echo "bundled acpmux ${commit:-unknown} (${source_kind}) from $src"
