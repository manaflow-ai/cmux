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

# A sparse harness checkout still builds the whole commit: the asked commit's reload.sh needs a file outside the
# harness's sparse set (git worktree add copies the sparse patterns, 2026-11-21).
mkdir -p "$repo/webviews"; echo '{}' >"$repo/webviews/package.json"
cat >"$repo/scripts/reload.sh" <<EOF
#!/usr/bin/env bash
[[ -f webviews/package.json ]] || { echo "no webviews/package.json" >&2; exit 1; }
mkdir -p "$root/whole.app"
echo "App path:"
echo "  $root/whole.app"
EOF
git -C "$repo" add webviews scripts/reload.sh
git -C "$repo" commit -q -m whole
whole="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" sparse-checkout set scripts
[[ ! -e "$repo/webviews/package.json" ]] || { echo "app-at-commit: the fixture's sparse checkout kept webviews/" >&2; exit 1; }
app="$(cd "$repo" && source "$lib" && measure_app_at_commit "$whole" t "$root/scratch/sparse" 2>"$root/sparse.err")" \
  || { echo "app-at-commit: a sparse harness built a partial commit: $(tail -n 3 "$root/sparse.err")" >&2; exit 1; }
[[ "$app" == "$root/whole.app" ]] || { echo "app-at-commit: sparse harness printed '$app'" >&2; exit 1; }
git -C "$repo" sparse-checkout disable

# A slow build prints progress on the step's stdout even when the caller sends stderr to a file, and the function
# returns as soon as the build ends (its progress loop does not hold the caller's $(...) open). 2026-11-26: the
# silent builds of a base/head pair were stopped as hung at the 45-minute limit.
cat >"$repo/scripts/reload.sh" <<EOF
#!/usr/bin/env bash
echo "compiling slowly"
sleep 3
mkdir -p "$root/slow.app"
echo "App path:"
echo "  $root/slow.app"
EOF
git -C "$repo" add scripts/reload.sh
git -C "$repo" commit -q -m slow
slow="$(git -C "$repo" rev-parse HEAD)"
t0="$(date +%s)"
(cd "$repo" && source "$lib" && app="$(MEASURE_BUILD_PROGRESS_S=1 measure_app_at_commit "$slow" slowtag "$root/scratch/slow" 2>"$root/slow.err")" && echo "app=$app") >"$root/slow.out"
elapsed=$(( $(date +%s) - t0 ))
grep -qx "app=$root/slow.app" "$root/slow.out" || { echo "app-at-commit: slow build printed: $(cat "$root/slow.out")" >&2; exit 1; }
grep -q "app-at-commit: still building slowtag .*compiling slowly" "$root/slow.out" \
  || { echo "app-at-commit: no progress line on stdout: $(cat "$root/slow.out")" >&2; exit 1; }
if grep -q "still building" "$root/slow.err"; then echo "app-at-commit: progress went to the caller's stderr" >&2; exit 1; fi
(( elapsed < 8 )) || { echo "app-at-commit: returned ${elapsed}s after a 3s build" >&2; exit 1; }

# A build that fails quietly returns its status and says why: with no error line, the log's last lines go to stderr.
# A bench passes CMUX_STRINGS_BEST_EFFORT=1, so a missing translation does not fail the build (2026-11-27).
cat >"$repo/scripts/reload.sh" <<EOF
#!/usr/bin/env bash
echo "strings best effort=\${CMUX_STRINGS_BEST_EFFORT:-unset}"
echo "settings: 80 strings missing"
exit 4
EOF
git -C "$repo" add scripts/reload.sh
git -C "$repo" commit -q -m quiet
quiet="$(git -C "$repo" rev-parse HEAD)"
rc=0
(cd "$repo" && source "$lib" && measure_app_at_commit "$quiet" quiettag "$root/scratch/quiet" 2>"$root/quiet.err" >/dev/null) || rc=$?
[[ "$rc" == 4 ]] || { echo "app-at-commit: a reload that exits 4 returned $rc" >&2; exit 1; }
grep -q "failed (status 4)" "$root/quiet.err" || { echo "app-at-commit: no failure line: $(cat "$root/quiet.err")" >&2; exit 1; }
grep -q "the reload log's last lines" "$root/quiet.err" || { echo "app-at-commit: no log tail on a quiet failure" >&2; exit 1; }
grep -q "strings best effort=1" "$root/quiet.err" || { echo "app-at-commit: reload.sh ran without CMUX_STRINGS_BEST_EFFORT=1" >&2; exit 1; }

# A commit nobody can fetch fails, and builds nothing.
if (cd "$repo" && CMUX_MEASURE_FETCH_URL="$repo" && export CMUX_MEASURE_FETCH_URL && source "$lib" && measure_app_at_commit 0123456789012345678901234567890123456789 t "$root/scratch/none" 2>/dev/null); then
  echo "app-at-commit: an unknown commit did not fail" >&2; exit 1
fi
echo "app-at-commit: builds the asked commit with its own reload.sh"
