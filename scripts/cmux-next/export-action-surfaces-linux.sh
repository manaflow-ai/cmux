#!/usr/bin/env bash
# Writes, or with --check compares, the action-catalog exports the Mac's Swift tests write
# (ActionSurfaceExport, ActionSurfaceReport, ActionCatalogDumpTests), on Linux:
#   plans/cmux-next/action-surfaces.json, the generated block of plans/cmux-next/actions.md and
#   plans/cmux-next/action-catalog.json (--only surfaces: the first two).
#
# The Swift exports read the catalog the app's pinned FFI holds (Packages/macOS/CmuxNext/app-ffi-pin.json),
# so this builds cmux-tui/crates/cmux-action-catalog as of the pin commit: the checkout's crate when it does
# not differ from the pin's (tests, benches and examples are not FFI inputs), else the pin commit's, fetched
# when missing. The exporter itself (the crate's examples/export-action-surfaces) and the string catalogs are
# the checkout's. The build runs in a one-crate workspace under cmux-tui/target/, so the rest of the cmux-tui
# workspace is not resolved.
#
# Usage: scripts/cmux-next/export-action-surfaces-linux.sh [--check] [--only surfaces|catalog]
# Exit: 0 written, or fresh under --check; 1 stale under --check (the files on stderr); 2 any error
# (build failure, missing pin commit, parse failure): a caller falls back to the Mac.
set -uo pipefail

fail() { echo "export-action-surfaces-linux: $*" >&2; exit 2; }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not in a git checkout"
cd "$root" || fail "cannot enter $root"
args=("$@")
for arg in "${args[@]}"; do
  case "$arg" in
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  esac
done

crate=cmux-tui/crates/cmux-action-catalog
read -r pin _ < <(python3 scripts/ci/app_ffi_pin.py read 2>/dev/null) || true
[[ "${pin:-}" =~ ^[0-9a-f]{40}$ ]] || fail "cannot read the FFI pin commit (python3 scripts/ci/app_ffi_pin.py read)"

if ! git cat-file -e "$pin^{commit}" 2>/dev/null; then
  git fetch --quiet --depth 1 --filter=blob:none origin "$pin" >&2 \
    || git fetch --quiet --depth 1 origin "$pin" >&2 \
    || fail "cannot fetch the pin commit $pin"
fi
git cat-file -e "$pin^{commit}" 2>/dev/null || fail "pin commit $pin is missing after fetching"

work="$root/cmux-tui/target/export-action-surfaces"
ws="$work/ws"
rm -rf "$ws" && mkdir -p "$ws/crates" || fail "cannot make $ws"

# The FFI's inputs in the crate, against the pin: app_ffi_pin.py's NOT_BUILT dirs left out.
inputs=("$crate" ":(exclude)$crate/tests" ":(exclude)$crate/benches" ":(exclude)$crate/examples")
if git diff --quiet "$pin" HEAD -- "${inputs[@]}" && git diff --quiet HEAD -- "${inputs[@]}"; then
  source_label="checkout (the crate matches the pin $pin)"
  cp -R "$crate" "$ws/crates/cmux-action-catalog" || fail "cannot copy $crate"
else
  source_label="pin commit $pin"
  git archive --format=tar "$pin" "$crate" | tar -x -C "$ws" || fail "cannot read $crate at $pin"
  mv "$ws/$crate" "$ws/crates/cmux-action-catalog" && rm -rf "$ws/cmux-tui" || fail "cannot stage $crate at $pin"
  rm -rf "$ws/crates/cmux-action-catalog/examples/export-action-surfaces"
  mkdir -p "$ws/crates/cmux-action-catalog/examples"
  cp -R "$crate/examples/export-action-surfaces" "$ws/crates/cmux-action-catalog/examples/" \
    || fail "cannot copy the exporter"
fi
echo "export-action-surfaces-linux: catalog from the $source_label" >&2

# The one-crate workspace: cmux-tui's package fields, lints and serde_json requirement, and its lock file.
python3 - "$root/cmux-tui/Cargo.toml" "$ws/Cargo.toml" <<'PY' || fail "cannot write the build workspace"
import json, sys, tomllib
workspace = tomllib.load(open(sys.argv[1], "rb"))["workspace"]
def value(v):
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{json.dumps(k)} = {value(x)}" for k, x in v.items()) + " }"
    return json.dumps(v)
lines = ["[workspace]", 'resolver = "2"', 'members = ["crates/cmux-action-catalog"]', "", "[workspace.package]"]
lines += [f"{k} = {value(v)}" for k, v in workspace.get("package", {}).items()]
lines += ["", "[workspace.dependencies]", f"serde_json = {value(workspace['dependencies']['serde_json'])}"]
for tool, table in workspace.get("lints", {}).items():
    lines += ["", f"[workspace.lints.{tool}]"] + [f"{json.dumps(k)} = {value(v)}" for k, v in table.items()]
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY
cp cmux-tui/Cargo.lock "$ws/Cargo.lock" || fail "cannot copy cmux-tui/Cargo.lock"

export CARGO_TARGET_DIR="$work/target"
(cd "$ws" && cargo build --quiet -p cmux-action-catalog --example export-action-surfaces) >&2 \
  || fail "the exporter does not build"
"$CARGO_TARGET_DIR/debug/examples/export-action-surfaces" --repo-root "$root" "${args[@]}"
status=$?
case "$status" in
  0|1) exit "$status" ;;
  *) exit 2 ;;
esac
