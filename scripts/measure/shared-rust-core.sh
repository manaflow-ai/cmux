#!/usr/bin/env bash
# CMUX-570: first link proof for the shared Rust core. Run on the fleet:
# cmux-ci test --setup rust --timeout 5400 --artifact artifacts/core-link -- \
#   bash scripts/measure/shared-rust-core.sh
# This verifies exports and the thin CLI. Its sizes are link payloads, NOT
# an installed-app comparison; both full app packaging arms still need one.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet shared-rust-core.sh 'cargo rustc' 'CMUX-570 combined Rust link'
crate="$root/cmux-tui/prototypes/cmux-app-core"
out="${FAST_CHECKS_OUT:-$root/artifacts/core-link}"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-core-link.XXXXXX")"
trap 'rm -rf "$work"' EXIT
target_dir="${CARGO_TARGET_DIR:-$root/cmux-tui/target/core-link}"
export CARGO_TARGET_DIR="$target_dir"
# Keep the allocator contract of the existing app FFI when SQLite is shared.
export LIBSQLITE3_FLAGS="${LIBSQLITE3_FLAGS:+$LIBSQLITE3_FLAGS }-DSQLITE_WITHOUT_ZONEMALLOC"

case "$(uname -s)" in
  Darwin)
    export MACOSX_DEPLOYMENT_TARGET=14.0
    lib=libcmux_core.dylib
    core_link=(-C 'link-arg=-Wl,-install_name,@rpath/libcmux_core.dylib')
    cli_link=(-C 'link-arg=-Wl,-rpath,@executable_path/../../Frameworks')
    ;;
  Linux)
    lib=libcmux_core.so
    core_link=()
    cli_link=(-C 'link-arg=-Wl,-rpath,$ORIGIN/../../Frameworks')
    ;;
  *) echo 'shared-rust-core: use a Linux or macOS fleet worker' >&2; exit 2 ;;
esac
(cd "$crate" && cargo rustc --locked --release --lib -- ${core_link[@]+"${core_link[@]}"})

# Read the existing packaging script's header inventory, so adding an app
# ABI cannot silently leave it out of the combined core.
sed -n '/^headers_in=(/,/)/p' "$root/scripts/cmux-next/build-app-ffi.sh" \
  | grep -oE '\$crates/[^" :]+\.h' | sed "s|\$crates|$root/cmux-tui/crates|" > "$work/headers"
while IFS= read -r header; do
  grep -oE '\bcmux_[a-z0-9_]+\(' "$header" | tr -d '('
done < "$work/headers" | sort -u > "$work/expected"
printf '%s\n' cmux_cli_main >> "$work/expected"
sort -u "$work/expected" -o "$work/expected"
if [[ "$(uname -s)" == Darwin ]]; then
  nm -gU "$target_dir/release/$lib" | awk '{print $NF}' | sed 's/^_//' | sort -u > "$work/actual"
else
  nm -D --defined-only "$target_dir/release/$lib" | awk '{print $NF}' | sort -u > "$work/actual"
fi
comm -23 "$work/expected" "$work/actual" > "$out/missing-exports.txt"
if [[ -s "$out/missing-exports.txt" ]]; then
  cat "$out/missing-exports.txt" >&2
  echo 'shared-rust-core: combined link lost app C ABI exports; do not package it' >&2
  exit 1
fi

app="$work/core-link.app"
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources/bin"
cp "$target_dir/release/$lib" "$app/Contents/Frameworks/"
(cd "$crate" && rustc --edition=2024 launcher.rs -O -C lto=fat -C strip=symbols \
  -L "native=$app/Contents/Frameworks" "${cli_link[@]}" -o "$app/Contents/Resources/bin/cmux")
python3 - "$app/Contents/Resources/bin/cmux" "$out/cmux-help.txt" <<'PY'
import subprocess, sys
with open(sys.argv[2], "w") as output:
    subprocess.run([sys.argv[1], "--help"], stdout=output, check=True, timeout=30)
PY
python3 - "$target_dir/release/$lib" "$target_dir/release/libcmux_core.a" \
  "$app/Contents/Resources/bin/cmux" "$out/link-bytes.json" <<'PY'
import json, pathlib, sys
library, archive, launcher, destination = map(pathlib.Path, sys.argv[1:])
report = {"kind": "link-payload-only", "shared_library_bytes": library.stat().st_size,
          "static_archive_bytes": archive.stat().st_size, "launcher_bytes": launcher.stat().st_size,
          "app_exports_present": True, "cli_help_passed": True}
destination.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
PY
