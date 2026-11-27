#!/usr/bin/env bash
# nightly-fresh-launch.sh's build_dmg (launch-ready.sh, background-ready.sh and quit-gamut.sh build their apps with it)
# gives each side its own tag. The tag names the app's daemon session, whose socket is one per user whatever HOME a
# launch has: with one tag for base and head, the owner a base launch kept for its terminals held that socket and every
# head launch's `server ensure` refused it as another state dir's (cmux#47182's A/B, 2026-11-20: the head arm never
# connected its daemon, never seeded, and attached no terminal in 19 launches). A stand-in repo whose reload.sh records
# its arguments builds base, then head; each must pass its own --tag.
set -euo pipefail

# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects; turns off background maintenance
measure="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$root"'
repo="$root/repo" out="$root/out"
mkdir -p "$repo/scripts" "$repo/GhosttyKit.xcframework" "$root/bin" "$out"
touch "$repo/GhosttyKit.xcframework/Info.plist"
git_fixture_init "$repo"
git -C "$repo" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m stand-in
cat >"$repo/scripts/reload.sh" <<EOF
#!/usr/bin/env bash
app="$root/app-\$#-\$RANDOM.app"
mkdir -p "\$app"
echo "\$*" >>"$root/reload-args"
echo "App path:"
echo "  \$app"
EOF
chmod +x "$repo/scripts/reload.sh"
# macOS tools build_dmg runs: the DMG is a file here. git's submodule update is a no-op (no submodules in the stand-in).
printf '#!/usr/bin/env bash\ntouch "${@: -1}"\n' >"$root/bin/hdiutil"
printf '#!/usr/bin/env bash\n[[ "$1" == submodule ]] && exit 0\nexec %q "$@"\n' "$(command -v git)" >"$root/bin/git"
chmod +x "$root/bin/hdiutil" "$root/bin/git"
export PATH="$root/bin:$PATH" CMUX_NEXT_ACPMUX_BIN=/stand-in/acpmux CMUX_NEXT_ACPMUX_ARCHS=arm64
fail() { echo "build-dmg-side-tags: $*" >&2; exit 1; }

sed '/^main "\$@"; exit \$?$/d' "$measure/nightly-fresh-launch.sh" >"$root/lib.sh"
# This library copy is outside the checkout, just as a saved carrier can be.
export NFL_BUILD_PROGRESS="$measure/build-progress.sh"
# shellcheck disable=SC1091 # the library copy made above
source "$root/lib.sh"
declare -F build_dmg >/dev/null || fail "no build_dmg in nightly-fresh-launch.sh"
cd "$repo"
build_dmg "$out" base release >/dev/null 2>&1 || fail "base build failed: $(cat "$out/build-base.log")"
build_dmg "$out" head release >/dev/null 2>&1 || fail "head build failed: $(cat "$out/build-head.log")"
[[ -f "$out/base.dmg" && -f "$out/head.dmg" ]] || fail "no DMG per side: $(ls "$out")"

tag_of() { sed -n "${1}p" "$root/reload-args" | sed -n 's/.*--tag \([^ ]*\).*/\1/p'; }
base_tag="$(tag_of 1)" head_tag="$(tag_of 2)"
[[ -n "$base_tag" && -n "$head_tag" ]] || fail "a build passed no --tag: $(cat "$root/reload-args")"
[[ "$base_tag" != "$head_tag" ]] || fail "base and head share the tag $base_tag, so their daemons share one session socket"
[[ "$base_tag" == nflab-base && "$head_tag" == nflab-head ]] || fail "tags $base_tag and $head_tag, want nflab-base and nflab-head"
echo "build-dmg-side-tags: ok (base $base_tag, head $head_tag)"
