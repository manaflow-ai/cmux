#!/usr/bin/env bash
# app-at-commit.sh builds the app with the asked commit's own reload.sh, not the harness checkout's, and prints the
# path that build printed. A stand-in repo: commit A's reload.sh prints one app path, commit B's another; the
# harness checkout sits at B and asks for A.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects; turns off background maintenance

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app-at-commit.sh"
root="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$root"'
repo="$root/repo"
mkdir -p "$repo/scripts"
git_fixture_init "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test

reload() { # reload NAME: a reload.sh that makes and prints the app NAME, and records its arguments
  cat >"$repo/scripts/reload.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$root/$1.app"
echo "\$*" >"$root/$1.args"
echo "App path:"
echo "  $root/$1.app"
EOF
  chmod +x "$repo/scripts/reload.sh"
  git -C "$repo" add scripts/reload.sh
  git -C "$repo" commit -q -m "$1"
}
reload base
base="$(git -C "$repo" rev-parse HEAD)"
reload head

app="$(cd "$repo" && source "$lib" && measure_app_at_commit "$base" mytag "$root/scratch/at" --config bench 2>/dev/null)"
[[ "$app" == "$root/base.app" ]] || { echo "app-at-commit: printed '$app', want $root/base.app (the asked commit's build)" >&2; exit 1; }
args="$(cat "$root/base.args")"
[[ "$args" == "--tag mytag --derived-data $repo/.build/DerivedData/cmux-measure-at --config bench" ]] \
  || { echo "app-at-commit: reload.sh got '$args'" >&2; exit 1; }
[[ ! -e "$root/head.app" ]] || { echo "app-at-commit: the harness checkout's reload.sh ran" >&2; exit 1; }

# A commit nobody can fetch fails, and builds nothing.
if (cd "$repo" && CMUX_MEASURE_FETCH_URL="$repo" && export CMUX_MEASURE_FETCH_URL && source "$lib" && measure_app_at_commit 0123456789012345678901234567890123456789 t "$root/scratch/none" 2>/dev/null); then
  echo "app-at-commit: an unknown commit did not fail" >&2; exit 1
fi
echo "app-at-commit: builds the asked commit with its own reload.sh"
