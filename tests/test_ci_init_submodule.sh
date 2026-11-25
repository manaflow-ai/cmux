#!/usr/bin/env bash
# Exercises scripts/ci/init-submodule.sh's cached git directory against a local
# file:// bucket: an exact pin checks out with the remote gone, a newer pin
# fetches only from the saved one, a miss fetches as before, a git directory
# already on the machine is never replaced, and `ghostty` never takes
# `ghostty-next`'s entry. 27 of 104 cmux-next fast tier (cargo) jobs on
# 2026-11-23 timed out cloning ghostty-next from github.com on Freestyle runners
# (job 137511000146); the cache is how those runners skip that clone.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/init-submodule.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Local file:// submodules need the protocol allowed; no user config leaks in.
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home" GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CMUX_LAN_CACHE_SOCKET="$WORK/no-lan-socket" INIT_SUBMODULE_ATTEMPTS=1
unset GITHUB_ACTIONS GITHUB_OUTPUT CI_CACHE_R2_NAMESPACE
mkdir -p "$HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The submodule's remote: one commit on main now, a second after the seed.
git init -q -b main "$WORK/remote"
echo one > "$WORK/remote/f"
git -C "$WORK/remote" add f
git -C "$WORK/remote" commit -qm one
old_pin="$(git -C "$WORK/remote" rev-parse HEAD)"

superproject() { # <dir> <submodule name and path> <url> <pin>
  git init -q -b main "$1"
  printf '[submodule "%s"]\n\tpath = %s\n\turl = %s\n' "$2" "$2" "$3" > "$1/.gitmodules"
  git -C "$1" add .gitmodules
  git -C "$1" update-index --add --cacheinfo "160000,$4,$2"
  git -C "$1" commit -qm super
}

# A bucket entry the way r2-cache.sh saves one: v1/any/objects/<key>.tar.gz and
# a latest/<prefix> pointer.
bucket="$WORK/bucket"
publish() { # <git dir> <key> <prefix>
  mkdir -p "$bucket/v1/any/objects" "$bucket/v1/any/latest"
  tar -czf "$bucket/v1/any/objects/$2.tar.gz" -C "$1" .
  printf '%s\n' "$2" > "$bucket/v1/any/latest/$3"
}

# A run that fetched: the git directory the cache would hold, at the old pin.
superproject "$WORK/seed" ghostty-next "file://$WORK/remote" "$old_pin"
(cd "$WORK/seed" && INIT_SUBMODULE_CACHE_URL= bash "$SCRIPT" ghostty-next) >/dev/null 2>&1 \
  || fail "the seeding run could not fetch"
prefix=submodule-gitdir-v1-ghostty_next-
publish "$WORK/seed/.git/modules/ghostty-next" "$prefix$old_pin" "$prefix"
echo two > "$WORK/remote/f"
git -C "$WORK/remote" commit -qam two
new_pin="$(git -C "$WORK/remote" rev-parse HEAD)"

# 1. The exact pin: checked out with the remote unreachable.
superproject "$WORK/exact" ghostty-next "file://$WORK/gone" "$old_pin"
out="$(cd "$WORK/exact" && INIT_SUBMODULE_CACHE_URL="file://$bucket" bash "$SCRIPT" ghostty-next 2>&1)" \
  || fail "exact pin from the cache: $out"
[[ "$(git -C "$WORK/exact/ghostty-next" rev-parse HEAD)" == "$old_pin" ]] || fail "exact pin not checked out"
[[ "$(cat "$WORK/exact/ghostty-next/f")" == one ]] || fail "exact pin work tree wrong"
grep -q "pin present: true" <<<"$out" || fail "exact pin not reported as a hit: $out"
# The origin is the superproject's, not the saving run's.
[[ "$(git -C "$WORK/exact/ghostty-next" config remote.origin.url)" == "file://$WORK/gone" ]] || fail "origin not reset"

# 2. A newer pin: the older entry by prefix, then a fetch of the difference.
superproject "$WORK/newer" ghostty-next "file://$WORK/remote" "$new_pin"
out="$(cd "$WORK/newer" && INIT_SUBMODULE_CACHE_URL="file://$bucket" bash "$SCRIPT" ghostty-next 2>&1)" \
  || fail "newer pin: $out"
[[ "$(git -C "$WORK/newer/ghostty-next" rev-parse HEAD)" == "$new_pin" ]] || fail "newer pin not checked out"
grep -q "pin present: false" <<<"$out" || fail "newer pin should restore by prefix: $out"

# 3. A miss (empty bucket): fetched from the remote as before.
superproject "$WORK/miss" ghostty-next "file://$WORK/remote" "$new_pin"
out="$(cd "$WORK/miss" && INIT_SUBMODULE_CACHE_URL="file://$WORK/empty-bucket" bash "$SCRIPT" ghostty-next 2>&1)" \
  || fail "miss: $out"
[[ "$(git -C "$WORK/miss/ghostty-next" rev-parse HEAD)" == "$new_pin" ]] || fail "miss not checked out"
grep -q "no cached ghostty-next git directory" <<<"$out" || fail "miss not reported: $out"

# 4. A git directory already here is kept (a restore would replace it).
touch "$WORK/miss/.git/modules/ghostty-next/marker"
git -C "$WORK/miss" submodule --quiet deinit -f ghostty-next
out="$(cd "$WORK/miss" && INIT_SUBMODULE_CACHE_URL="file://$bucket" bash "$SCRIPT" ghostty-next 2>&1)" \
  || fail "existing git dir: $out"
[[ -e "$WORK/miss/.git/modules/ghostty-next/marker" ]] || fail "an existing git directory was replaced"

# 5. `ghostty` never restores `ghostty-next`'s entry (their prefixes differ).
superproject "$WORK/other" ghostty "file://$WORK/remote" "$old_pin"
out="$(cd "$WORK/other" && INIT_SUBMODULE_CACHE_URL="file://$bucket" bash "$SCRIPT" ghostty 2>&1)" \
  || fail "ghostty: $out"
grep -q "no cached ghostty git directory" <<<"$out" || fail "ghostty took another submodule's entry: $out"

# 6. Off CI the cache is off unless asked for: no URL, no restore line.
superproject "$WORK/local" ghostty-next "file://$WORK/remote" "$old_pin"
out="$(cd "$WORK/local" && bash "$SCRIPT" ghostty-next 2>&1)" || fail "local: $out"
! grep -q "cache" <<<"$out" || fail "the cache ran outside CI: $out"

# 7. --seed: a pin the bucket holds is not fetched again (the remote is gone);
# one it lacks needs the write credentials before anything is fetched.
superproject "$WORK/seeded" ghostty-next "file://$WORK/gone" "$old_pin"
out="$(cd "$WORK/seeded" && INIT_SUBMODULE_CACHE_URL="file://$bucket" bash "$SCRIPT" --seed ghostty-next 2>&1)" \
  || fail "seed of a cached pin: $out"
grep -q "already holds $prefix$old_pin" <<<"$out" || fail "seed refetched a cached pin: $out"
superproject "$WORK/unseeded" ghostty-next "file://$WORK/remote" "$new_pin"
if out="$(cd "$WORK/unseeded" && env -u AWS_ACCESS_KEY_ID INIT_SUBMODULE_CACHE_URL="file://$bucket" \
    bash "$SCRIPT" --seed ghostty-next 2>&1)"; then
  fail "a seed with no credentials passed: $out"
fi
grep -q "needs AWS_ACCESS_KEY_ID" <<<"$out" || fail "seed without credentials: $out"
[[ ! -e "$WORK/unseeded/.git/modules/ghostty-next" ]] || fail "seed fetched with no way to save"

echo "PASS: init-submodule cache (exact, prefix, miss, keep, name, off, seed)"
