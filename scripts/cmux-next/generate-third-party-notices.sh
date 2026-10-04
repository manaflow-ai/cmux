#!/usr/bin/env bash
# Generates THIRD_PARTY_LICENSES.md for the cmux-next app bundle.
#
#   scripts/cmux-next/generate-third-party-notices.sh          rewrite the file
#   scripts/cmux-next/generate-third-party-notices.sh --check  fail when it is stale
#
# The file is the hand-written input (scripts/cmux-next/notices/hand-written.md,
# owned by the license review, copied byte for byte with section markers) plus
# one generated section per bundled Rust binary (cmux-tui/build-support/notices/
# rust_notices.py; union of aarch64 and x86_64 macOS closures):
#
#   rust-cmux-cli           bin/cmux and bin/cmux-tui-ssh/*  cmux-tui/Cargo.lock at the cmux-tui pin
#   rust-cmux-app-host      bin/cmux-app-host                cmux-tui/Cargo.lock at the cmux-tui pin
#   rust-cmux-cloud         bin/cmux-cloud                   first-party-apps/cloud/server at the pin
#   rust-cmux-diff-sidecar  bin/cmux-diff-sidecar            Native/DiffSidecar/Cargo.lock (this tree)
#   rust-iroh-ffi           Iroh.framework                   manaflow-ai/iroh-ffi at the Package.resolved revision
#
# The release bundles the cmux-tui pin's binaries (scripts/cmux-next/cmux-tui.pin),
# so their closures come from that commit; first-party crates point at the
# permanent tag cmux-tui-src-<pin, 11 characters>, which must exist.
#
# No cargo: crate sources come from crates.io and git into a CARGO_HOME-shaped
# cache (CMUX_NOTICES_CACHE, default ~/.cache/cmux-notices; fetch_crates.py
# checks every .crate against its Cargo.lock sha256). The first run needs the
# network; later runs reuse the cache. scripts/verify-app-bundle-licenses.sh
# checks the bundled result against scripts/cmux-next/notices/bundle-map.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NOTICES="$ROOT/cmux-tui/build-support/notices"
CACHE="${CMUX_NOTICES_CACHE:-$HOME/.cache/cmux-notices}"
CHECK=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

pin="$(sed -n 's/^commit=//p' "$ROOT/scripts/cmux-next/cmux-tui.pin")"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no commit= line in scripts/cmux-next/cmux-tui.pin" >&2; exit 1; }
tag="cmux-tui-src-${pin:0:11}"
if ! git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
  echo "error: source tag $tag (the cmux-tui pin) does not exist on origin; first-party crates must point at a permanent tag" >&2
  exit 1
fi

iroh_rev="$(python3 -c 'import json, sys
pins = [p for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "iroh-ffi"]
print(pins[0]["state"]["revision"])' "$ROOT/Packages/macOS/CmuxNext/Package.resolved")"
[[ "$iroh_rev" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no iroh-ffi revision in Packages/macOS/CmuxNext/Package.resolved" >&2; exit 1; }

mkdir -p "$CACHE"
pin_src="$CACHE/cmux-src-$pin"
if [[ ! -d "$pin_src" ]]; then
  git -C "$ROOT" cat-file -e "$pin^{commit}" 2>/dev/null || git -C "$ROOT" fetch --quiet origin "$pin"
  rm -rf "$pin_src.partial" && mkdir -p "$pin_src.partial"
  git -C "$ROOT" archive "$pin" cmux-tui first-party-apps/cloud/server | tar -x -C "$pin_src.partial"
  mv "$pin_src.partial" "$pin_src"
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

python3 "$NOTICES/fetch_crates.py" --cache "$CACHE" \
  --lock "$pin_src/cmux-tui/Cargo.lock" \
  --lock "$pin_src/first-party-apps/cloud/server/Cargo.lock" \
  --lock "$ROOT/Native/DiffSidecar/Cargo.lock" \
  --lock "$iroh_src/Cargo.lock"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

section() {
  local id="$1" title="$2"
  shift 2
  CARGO_HOME="$CACHE" python3 "$NOTICES/rust_notices.py" \
    --reviewed "$NOTICES/reviewed.json" \
    --first-party-license "$ROOT/cmux-tui/dist/npm/cmux/LICENSE" \
    --source-tag "$tag" \
    --target aarch64-apple-darwin --target x86_64-apple-darwin \
    --format markdown --section-id "$id" --title "$title" \
    --out "$work/$id.md" "$@"
}

pin_label="at the cmux-tui pin ${pin:0:11}"
section rust-cmux-cli "Rust crates: cmux CLI and daemon (bin/cmux)" \
  --lock "$pin_src/cmux-tui/Cargo.lock" --lock-label "cmux-tui/Cargo.lock $pin_label" \
  --root cmux-tui --root acpmux --workspace "$pin_src/cmux-tui" --repo-root "$pin_src" \
  --first-party 'cmux-tui/crates/*' --first-party 'cmux-tui/bindings/*'
section rust-cmux-app-host "Rust crates: app host (bin/cmux-app-host)" \
  --lock "$pin_src/cmux-tui/Cargo.lock" --lock-label "cmux-tui/Cargo.lock $pin_label" \
  --root cmux-app-host --workspace "$pin_src/cmux-tui" --repo-root "$pin_src" \
  --first-party 'cmux-tui/crates/*' --first-party 'cmux-tui/bindings/*'
section rust-cmux-cloud "Rust crates: Cloud app server (bin/cmux-cloud)" \
  --lock "$pin_src/first-party-apps/cloud/server/Cargo.lock" --lock-label "first-party-apps/cloud/server/Cargo.lock $pin_label" \
  --root cmux-cloud --workspace "$pin_src/first-party-apps/cloud/server" --workspace "$pin_src/cmux-tui" --repo-root "$pin_src" \
  --first-party 'first-party-apps/cloud/server' --first-party 'cmux-tui/crates/*' --first-party 'cmux-tui/bindings/*'
section rust-cmux-diff-sidecar "Rust crates: diff viewer sidecar (bin/cmux-diff-sidecar)" \
  --lock "$ROOT/Native/DiffSidecar/Cargo.lock" --lock-label "Native/DiffSidecar/Cargo.lock" \
  --root cmux-diff-sidecar --workspace "$ROOT/Native/DiffSidecar" --repo-root "$ROOT" \
  --first-party 'Native/DiffSidecar'
section rust-iroh-ffi "Rust crates: Iroh.framework (manaflow-ai/iroh-ffi)" \
  --lock "$iroh_src/Cargo.lock" --lock-label "manaflow-ai/iroh-ffi Cargo.lock at ${iroh_rev:0:11}" \
  --root iroh-ffi --workspace "$iroh_src" \
  --path-download "git+https://github.com/manaflow-ai/iroh-ffi.git@$iroh_rev"

compose=(python3 "$ROOT/scripts/cmux-next/notices/compose_notices.py"
  --hand-written "$ROOT/scripts/cmux-next/notices/hand-written.md"
  --section "$work/rust-cmux-cli.md" --section "$work/rust-cmux-app-host.md"
  --section "$work/rust-cmux-cloud.md" --section "$work/rust-cmux-diff-sidecar.md"
  --section "$work/rust-iroh-ffi.md"
  --out "$ROOT/THIRD_PARTY_LICENSES.md")
review=(python3 "$NOTICES/review_list.py" --cache "$CACHE"
  --lock "$pin_src/cmux-tui/Cargo.lock" --lock "$pin_src/first-party-apps/cloud/server/Cargo.lock"
  --lock "$ROOT/Native/DiffSidecar/Cargo.lock" --lock "$iroh_src/Cargo.lock")
if [[ "$CHECK" == 1 ]]; then
  "${review[@]}" --check
  "${compose[@]}" --check
  echo "THIRD_PARTY_LICENSES.md is current"
else
  "${review[@]}"
  "${compose[@]}"
  echo "wrote THIRD_PARTY_LICENSES.md ($(wc -c < "$ROOT/THIRD_PARTY_LICENSES.md" | tr -d ' ') bytes)"
fi
