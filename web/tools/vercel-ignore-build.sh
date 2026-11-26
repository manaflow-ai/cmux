#!/usr/bin/env bash

# Vercel runs this from the project root, which is web/. Return 0 to skip the
# build and 1 to continue it. Build only when a web build input changed, or
# when no source below can say whether one did.
#
# A skip shows in Vercel as a "Canceled" production deployment whose log ends
# with "No web build inputs changed": expected for a main commit outside web/.
# A production deployment cancelled before it clones (no build log) is
# .github/workflows/classic-deploy-guard.yml refusing the commit instead; its run
# on that push names why.

previous_sha="${VERCEL_GIT_PREVIOUS_SHA:-}"
current_sha="${VERCEL_GIT_COMMIT_SHA:-HEAD}"

# Build for unknown web paths so a new production directory or configuration
# file cannot silently skip deployment. Exclude only known non-build inputs.
# web_exclusions are git pathspecs relative to web/, one literal per line
# (tests/test_ci_classic_deploy_guard.py reads them against the classic deploy
# guard's list); shared_inputs are relative to the repository root. Both the
# git comparison and the GitHub API comparison below read these two lists.
web_exclusions=(
  ":(exclude)tests/"
  ":(exclude)e2e/"
  ":(exclude)scripts/"
  ":(exclude)README.md"
  ":(exclude)AGENTS.md"
  ":(exclude)CLAUDE.md"
)
shared_inputs=(
  .vercelignore
  CHANGELOG.md
  config/iroh/managed-relay-catalog.json
  workers/presence/src/generated/managedRelayCatalog.ts
)

# Where the previous commit can be fetched or compared when this clone lacks
# it. The repository is public, so neither needs a credential. The two
# CMUX_VERCEL_IGNORE_* overrides exist for web/tests/vercel-ignore-build.test.ts.
repository="${VERCEL_GIT_REPO_OWNER:-manaflow-ai}/${VERCEL_GIT_REPO_SLUG:-cmux}"
public_remote="${CMUX_VERCEL_IGNORE_PUBLIC_REMOTE:-https://github.com/${repository}.git}"
github_api="${CMUX_VERCEL_IGNORE_GITHUB_API:-https://api.github.com}"

if [[ -z "$previous_sha" ]]; then
  echo "No previous Vercel deployment SHA; running the build."
  exit 1
fi

has_commit() {
  git cat-file -e "${1}^{commit}" 2>/dev/null
}

# Prints the last lines of a failure with any credential in a URL removed.
say_failure() {
  printf '%s\n' "$2" | tail -n 3 | sed -E 's#://[^/@[:space:]]+@#://#g; s#^#  #'
  echo "  (${1})"
}

# Fetches the previous commit from one remote. Never lets this hold the build
# open: terminal prompts are off and `timeout` bounds it (without `timeout`
# it is not tried). Depth 1 only in a shallow clone (Vercel's): run from a
# full clone, --depth would write .git/shallow and truncate history for every
# worktree sharing it. `git diff` only needs both trees, not a connected
# history between them, so one commit is enough.
fetch_previous() {
  local remote="$1" label="$2" output status depth=()
  if ! command -v timeout >/dev/null 2>&1; then
    echo "No timeout command; not fetching from ${label}."
    return 1
  fi
  [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1)
  output="$(GIT_TERMINAL_PROMPT=0 timeout 60 git fetch --no-tags --no-recurse-submodules \
    --quiet ${depth[@]+"${depth[@]}"} "$remote" "$previous_sha" 2>&1)"
  status=$?
  if [[ $status -eq 0 ]] && has_commit "$previous_sha"; then
    echo "Fetched the previous Vercel deployment commit from ${label}."
    return 0
  fi
  echo "Could not fetch the previous Vercel deployment commit from ${label}:"
  if [[ $status -eq 124 ]]; then
    say_failure "git fetch timed out after 60 s" "$output"
  else
    say_failure "git fetch exit status ${status}" "$output"
  fi
  return 1
}

# GitHub's compare API lists the paths a range changed. Use it only when the
# previous commit is an ancestor of the current one (status "ahead" or
# "identical"), so the list is the same as a tree diff, and only when the list
# is complete (GitHub returns at most 300 files).
compare_with_github() {
  local current response verdict
  current="$(git rev-parse --verify --quiet "${current_sha}^{commit}")" || {
    echo "  (the current commit ${current_sha} is not in this clone)"
    return 2
  }
  command -v curl >/dev/null 2>&1 || { echo "  (no curl)"; return 2; }
  command -v node >/dev/null 2>&1 || { echo "  (no node)"; return 2; }
  local headers=(-H "Accept: application/vnd.github+json")
  [[ -n "${GITHUB_TOKEN:-}" ]] && headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  if ! response="$(curl --fail --silent --show-error --location --max-time 30 \
    "${headers[@]}" "${github_api}/repos/${repository}/compare/${previous_sha}...${current}?per_page=100" 2>&1)"; then
    say_failure "curl" "$response"
    return 2
  fi
  verdict="$(WEB_PREFIX="$(git rev-parse --show-prefix)" \
    NON_INPUTS="$(printf '%s\n' "${web_exclusions[@]#:(exclude)}")" \
    SHARED_INPUTS="$(printf '%s\n' "${shared_inputs[@]}")" \
    node -e '
      let input = "";
      process.stdin.on("data", (chunk) => { input += chunk; });
      process.stdin.on("end", () => {
        let compare;
        try { compare = JSON.parse(input); } catch { console.log("unknown: not JSON"); return; }
        if (!["ahead", "identical"].includes(compare.status)) {
          console.log(`unknown: status ${compare.status}`);
          return;
        }
        const files = Array.isArray(compare.files) ? compare.files : [];
        if (files.length >= 300) { console.log("unknown: GitHub truncated the file list"); return; }
        const web = process.env.WEB_PREFIX;
        const lines = (name) => (process.env[name] ?? "").split("\n").filter(Boolean);
        const nonInputs = lines("NON_INPUTS");
        const shared = new Set(lines("SHARED_INPUTS"));
        const isInput = (path) => {
          if (shared.has(path)) return true;
          if (!path.startsWith(web)) return false;
          const rest = path.slice(web.length);
          return !nonInputs.some((entry) =>
            entry.endsWith("/") ? rest.startsWith(entry) : rest === entry || rest.startsWith(`${entry}/`));
        };
        const paths = files.flatMap((file) => [file.filename, file.previous_filename]).filter(Boolean);
        const changed = paths.filter(isInput);
        console.log(changed.length > 0 ? `changed: ${changed[0]}` : "unchanged");
      });
    ' <<<"$response" 2>&1)"
  case "$verdict" in
    unchanged) return 0 ;;
    changed:*) echo "  (${verdict})"; return 1 ;;
  esac
  echo "  (${verdict})"
  return 2
}

compare_with_git() {
  local pathspecs=("." "${web_exclusions[@]}") path
  for path in "${shared_inputs[@]}"; do pathspecs+=("../${path}"); done
  git diff --quiet "$previous_sha" "$current_sha" -- "${pathspecs[@]}"
  case $? in
    0)
      echo "No web build inputs changed; skipping the Vercel build."
      exit 0
      ;;
    1)
      echo "Web build inputs changed; running the Vercel build."
      exit 1
      ;;
  esac
  echo "git could not compare ${previous_sha} with ${current_sha}; running the build."
  exit 1
}

has_commit "$previous_sha" && compare_with_git

# Vercel builds from a clone 10 commits deep, and main lands commits faster
# than that, so the previously deployed commit is usually outside it. From
# 2026-11-15 to 2026-11-22 every commit that left 10 commits since the last
# build was built and deployed even when nothing it shipped had changed: the
# fetch from origin failed in Vercel's container (its error went unprinted)
# and the script built defensively. Ask the compare API first: one request,
# about a second. A fetch of the previous commit downloads its whole tree
# (about 12 s from a GitHub runner); try origin, then the public URL, which
# needs no credential.
echo "Previous Vercel deployment commit ${previous_sha} is not in this clone; asking GitHub's compare API."
compare_with_github
case $? in
  0)
    echo "No web build inputs changed (GitHub compare API); skipping the Vercel build."
    exit 0
    ;;
  1)
    echo "Web build inputs changed (GitHub compare API); running the Vercel build."
    exit 1
    ;;
esac

if git remote get-url origin >/dev/null 2>&1; then
  fetch_previous origin "origin" || fetch_previous "$public_remote" "$public_remote"
else
  echo "This clone has no origin remote."
  fetch_previous "$public_remote" "$public_remote"
fi
has_commit "$previous_sha" && compare_with_git

echo "Could not tell whether web build inputs changed; running the build."
exit 1
