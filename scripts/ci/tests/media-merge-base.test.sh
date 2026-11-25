#!/usr/bin/env bash
# media_merge_base.sh: GitHub's answer when it has one; otherwise git's, from a
# shallow clone deepened past the boundary that hides the real base (the API's
# rate limit failed nightly tour 45142205045 at this step).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../media_merge_base.sh"
tmp="$(mktemp -d)"
trap 'cd /; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0 GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false GIT_CONFIG_KEY_2=core.hooksPath GIT_CONFIG_VALUE_2=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GITHUB_REPOSITORY=o/r

# origin: a fork point, 150 commits on each side of it.
git init -q -b main "$tmp/origin"
c() { git -C "$tmp/origin" commit -q --allow-empty -m "$1"; }
c root; for i in $(seq 1 5); do c "trunk $i"; done
fork="$(git -C "$tmp/origin" rev-parse HEAD)"
git -C "$tmp/origin" checkout -q -b side
for i in $(seq 1 150); do c "side $i"; done
head="$(git -C "$tmp/origin" rev-parse HEAD)"
git -C "$tmp/origin" checkout -q main
for i in $(seq 1 150); do c "main $i"; done
base="$(git -C "$tmp/origin" rev-parse HEAD)"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_STUB_ANSWER:-}" ] && { echo "$GH_STUB_ANSWER"; exit 0; }
echo "gh: API rate limit exceeded for installation." >&2; exit 1
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# A depth-2 clone, as the workflow's checkout.
git clone -q --depth=2 --no-local "file://$tmp/origin" "$tmp/work" 2>/dev/null
cd "$tmp/work"

# The API answers: its answer, no fetch.
got="$(GH_STUB_ANSWER="$fork" bash "$script" "$base" "$head")"
[ "$got" = "$fork" ] || fail "API answer not used: $got"

# The API fails: git finds the real fork point past the shallow boundary.
got="$(bash "$script" "$base" "$head" 2>/dev/null)" || fail "no fallback answer"
[ "$got" = "$fork" ] || fail "fallback gave $got, want $fork"

# The same commit is its own merge base.
[ "$(bash "$script" "$base" "$base")" = "$base" ] || fail "same sha"

echo "media-merge-base: ok"
