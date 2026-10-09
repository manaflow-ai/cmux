#!/usr/bin/env bash
# Builds this checkout's cmux-tui client set on a build host whose tree is not
# published: cmux-tui and the companions the bundle scripts install beside it
# (cmux-app-host, cmux-cloud, cmux-browser-host). reload.sh uses it for an
# nx-remote build (NX_JOB_ID) when pin-cmux-tui.sh probe does not report the
# tree ready, and hands the result to the bundle as CMUX_TUI_CLIENT_LOCAL, so
# the build neither stops nor waits for a cmux-tui-artifacts run (a newer push
# to the branch replaces a pending run, so a busy branch's older trees are
# never published; cx-t3e5). The fleet recipe builds the same set
# (build-fleet/recipes/cmux-tui-client.sh in cmuxterm-hq).
#
#   build-cmux-tui-client.sh [--print-path] [--check-build-allowed]
#
# Output: cmux-tui/target/client-local/<tree key>/ (reused while the tree key
# and the build commit's tree key match). Cargo builds in the persistent
# cmux-tui/target/client-app (CMUX_TUI_CLIENT_TARGET_DIR), so the next commit
# compiles incrementally. A developer Mac never runs Cargo (same rule as
# build-acpmux.sh).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pin="$repo_root/scripts/cmux-next/pin-cmux-tui.sh"

build_allowed() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}${NX_JOB_ID:-}" ]]; }

print_path=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-path) print_path=1; shift ;;
    --check-build-allowed) build_allowed; exit $? ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { if [[ "$print_path" -eq 1 ]]; then echo "$@" >&2; else echo "$@"; fi; }

key="$("$pin" key)"
[[ "$key" =~ ^[0-9a-f]{40,64}$ ]] || { echo "error: no cmux-tui tree key for this checkout" >&2; exit 1; }
out="$repo_root/cmux-tui/target/client-local/$key"
# Uncommitted edits (an nx-remote warm tree syncs them) are not in the key:
# such a tree always rebuilds, incrementally.
dirty="$(git -C "$repo_root" status --porcelain --untracked-files=normal -- cmux-tui first-party-apps/cloud/server ghostty-next 2>/dev/null | grep -v ' cmux-tui/target/' || true)"
if [[ -z "$dirty" ]] && "$pin" local-build "$out/cmux-tui" >/dev/null 2>&1; then
  say "cmux-tui client set for tree $key already built: $out"
  [[ "$print_path" -eq 0 ]] || printf '%s\n' "$out/cmux-tui"
  exit 0
fi
build_allowed || {
  echo "error: cmux-tui tree $key is not built here, and this machine never runs Cargo; build through nx-remote or the fleet" >&2
  exit 1
}
command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required to build cmux-tui" >&2; exit 1; }

commit="$(git -C "$repo_root" rev-parse HEAD)"
vt_source=ghostty
git -C "$repo_root" rev-parse --verify -q HEAD:ghostty-next >/dev/null && vt_source=ghostty-next
ghostty_commit="$(git -C "$repo_root/$vt_source" rev-parse HEAD 2>/dev/null || true)"
target_dir="${CMUX_TUI_CLIENT_TARGET_DIR:-$repo_root/cmux-tui/target/client-app}"
mkdir -p "$target_dir"
stage="$(mktemp -d "$repo_root/cmux-tui/target/.client-local.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

say "==> building cmux-tui for tree $key ($commit)"
(cd "$repo_root/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$commit" CMUX_TUI_GHOSTTY_COMMIT="$ghostty_commit" \
  CARGO_TARGET_DIR="$target_dir" cargo build -p cmux-tui --bin cmux-tui --release --locked >&2)
install -m 755 "$target_dir/release/cmux-tui" "$stage/cmux-tui"

# The companions this source bundles beside cmux-tui: the ones its bundle
# scripts name (the fleet recipe decides the same way).
for name in cmux-app-host cmux-cloud cmux-browser-host; do
  named=0
  for script in scripts/cmux-next/bundle-cmux-tui.sh scripts/install-cmux-tui-client.sh; do
    if [[ -f "$repo_root/$script" ]] && grep -q -- "$name" "$repo_root/$script"; then named=1; fi
  done
  [[ "$named" -eq 1 ]] || continue
  case "$name" in
    cmux-cloud) dir="first-party-apps/cloud/server" ;;
    *) dir="cmux-tui/crates/$name" ;;
  esac
  [[ -f "$repo_root/$dir/Cargo.toml" ]] || { echo "error: this source bundles $name but has no $dir/Cargo.toml" >&2; exit 1; }
  say "==> building $name beside cmux-tui"
  if [[ "$name" == cmux-cloud ]]; then
    (cd "$repo_root/$dir" && CARGO_TARGET_DIR="$target_dir" cargo build --bin "$name" --release --locked >&2)
  else
    (cd "$repo_root/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$commit" CARGO_TARGET_DIR="$target_dir" \
      cargo build -p "$name" --bin "$name" --release --locked >&2)
  fi
  install -m 755 "$target_dir/release/$name" "$stage/$name"
done

rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
trap - EXIT
say "built the cmux-tui client set for tree $key: $out"
[[ "$print_path" -eq 0 ]] || printf '%s\n' "$out/cmux-tui"
