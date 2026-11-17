#!/usr/bin/env bash
# tab-switch.sh checks that each submodule commit its build checks out can be fetched before it builds: a step hit
# "cannot fetch" on a ghostty pointer only after it had taken the host (a fleet Mac, 2026-11-16). Here the script runs in a
# scratch superproject whose ghostty pointer and remotes are local file:// repositories (no network), with a stub
# GhosttyKit download that stops it right after the check: a fetchable pointer passes; a pointer the fork lacks, a
# host mirror older than the pointer, and an unreachable remote each exit 3 with a TSW line naming which.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../tab-switch.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tab-switch-submodule-refs.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

home="$tmp/home"
mkdir -p "$home"
export HOME="$home" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid
git config --global user.name t
git config --global protocol.file.allow always
git config --global init.defaultBranch main

# The fork: serves any commit by id (as GitHub does) and partial clones.
fork="$tmp/fork.git"
git init -q "$tmp/fork-work"
git -C "$tmp/fork-work" commit -q --allow-empty -m one
pushed="$(git -C "$tmp/fork-work" rev-parse HEAD)"
git -C "$tmp/fork-work" commit -q --allow-empty -m two
newer="$(git -C "$tmp/fork-work" rev-parse HEAD)"
git clone -q --bare "$tmp/fork-work" "$fork"
git -C "$fork" config uploadpack.allowAnySHA1InWant true
git -C "$fork" config uploadpack.allowFilter true
unpushed=0123456789abcdef0123456789abcdef01234567
# A mirror that stopped before the newer commit.
mirror="$tmp/mirror.git"
git clone -q --bare "$tmp/fork-work" "$mirror"
git -C "$mirror" update-ref refs/heads/main "$pushed"
git -C "$mirror" reflog expire --expire=now --all
git -C "$mirror" gc -q --prune=now
git -C "$mirror" config uploadpack.allowAnySHA1InWant true
git -C "$mirror" config uploadpack.allowFilter true

superproject() { # NAME POINTER URL: a repository whose HEAD records ghostty and ghostty-next at POINTER from URL
  local repo="$tmp/$1"
  mkdir -p "$repo/scripts/measure"
  cp "$script" "$repo/scripts/measure/tab-switch.sh"
  printf '#!/usr/bin/env bash\necho PAST_CHECK >&2\nexit 97\n' >"$repo/scripts/download-prebuilt-ghosttykit.sh"
  chmod +x "$repo/scripts/download-prebuilt-ghosttykit.sh"
  git -C "$repo" init -q
  local sub
  for sub in ghostty ghostty-next; do
    printf '[submodule "%s"]\n\tpath = %s\n\turl = %s\n' "$sub" "$sub" "$3" >>"$repo/.gitmodules"
  done
  git -C "$repo" add .gitmodules scripts
  for sub in ghostty ghostty-next; do
    git -C "$repo" update-index --add --cacheinfo "160000,$2,$sub"
  done
  git -C "$repo" commit -q -m fixture
  echo "$repo"
}

fails=0
run() { # NAME EXPECT_EXIT EXPECT_TEXT REPO
  local name="$1" want="$2" text="$3" repo="$4" out rc start
  start=$SECONDS
  set +e
  out="$(cd "$repo" && CMUX_CEF_R2_ACCOUNT_ID=a CMUX_CEF_R2_ACCESS_KEY_ID=b CMUX_CEF_R2_SECRET_ACCESS_KEY=c \
    bash scripts/measure/tab-switch.sh --rounds=1 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" != "$want" || "$out" != *"$text"* || $((SECONDS - start)) -gt 10 ]]; then
    echo "FAIL $name: exit $rc (want $want), $((SECONDS - start)) s; output:"
    echo "$out" | head -n 20
    fails=$((fails + 1))
  else
    echo "ok   $name"
  fi
}

run "a pointer the fork has passes" 97 PAST_CHECK "$(superproject ok "$newer" "file://$fork")"
run "a pointer the fork lacks fails before building" 3 "was never pushed to the fork" \
  "$(superproject unpushed "$unpushed" "file://$fork")"
run "an unreachable remote fails before building" 3 "cannot be reached from this host" \
  "$(superproject gone "$newer" "file://$tmp/no-such.git")"
git config --global "url.file://$mirror.insteadOf" "file://$fork"
run "a stale mirror fails before building and names it" 3 "mirror file://$mirror lacks it" \
  "$(superproject stale "$newer" "file://$fork")"
run "a mirror that has the pointer passes" 97 PAST_CHECK "$(superproject fresh "$pushed" "file://$fork")"

if [[ "$fails" -gt 0 ]]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "tab-switch submodule ref check: all cases passed"
