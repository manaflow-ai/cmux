#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP' >&2
Usage: ./scripts/bump-version.sh <new-version|major|minor|patch>
Examples:
  ./scripts/bump-version.sh 1.2.3
  ./scripts/bump-version.sh patch
HELP
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

BUMP_TARGET="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to run bump-version.sh" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to run bump-version.sh" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Working tree has tracked changes. Commit or stash them before bumping." >&2
  exit 1
fi

current_version="$(node -e 'console.log(require("./apps/client/package.json").version)')"

if [[ -z "$current_version" ]]; then
  echo "Unable to read current version from apps/client/package.json." >&2
  exit 1
fi

if [[ ! "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Current version \"$current_version\" is not in the expected x.y.z format." >&2
  exit 1
fi

case "$BUMP_TARGET" in
  major|minor|patch)
    IFS='.' read -r major minor patch <<< "$current_version"
    case "$BUMP_TARGET" in
      major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
      minor)
        minor=$((minor + 1))
        patch=0
        ;;
      patch)
        patch=$((patch + 1))
        ;;
    esac
    new_version="${major}.${minor}.${patch}"
    ;;
  *)
    new_version="$BUMP_TARGET"
    ;;
esac

if [[ ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version \"$new_version\" is not a valid semver (x.y.z)." >&2
  exit 1
fi

if [[ "$new_version" == "$current_version" ]]; then
  echo "New version matches current version ($current_version). Nothing to do." >&2
  exit 1
fi

read -r current_major current_minor current_patch <<< "$(printf '%s' "$current_version" | tr '.' ' ')"
read -r next_major next_minor next_patch <<< "$(printf '%s' "$new_version" | tr '.' ' ')"

if (( next_major < current_major )) || \
   (( next_major == current_major && next_minor < current_minor )) || \
   (( next_major == current_major && next_minor == current_minor && next_patch < current_patch )); then
  echo "New version $new_version is lower than current version $current_version." >&2
  exit 1
fi

update_version_file() {
  local file="$1"
  local version="$2"

  if [[ ! -f "$file" ]]; then
    echo "Version file $file not found." >&2
    exit 1
  fi

  TARGET_FILE="$file" TARGET_VERSION="$version" node <<'NODE'
    import { readFileSync, writeFileSync } from "node:fs";

    const file = process.env.TARGET_FILE;
    const version = process.env.TARGET_VERSION;

    const json = JSON.parse(readFileSync(file, "utf8"));
    json.version = version;
    writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
NODE
}

version_files=("apps/client/package.json")

for file in "${version_files[@]}"; do
  update_version_file "$file" "$new_version"
  git add "$file"
done

echo "Bumping version from $current_version to $new_version"

git commit -m "chore: bump version to $new_version"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" == "HEAD" ]]; then
  echo "You are in a detached HEAD state. Check out a branch before bumping." >&2
  exit 1
fi

first_remote="$(git remote | head -n 1)"
if [[ -z "$first_remote" ]]; then
  echo "No git remote configured. Add a remote before bumping." >&2
  exit 1
fi

if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name @{u})"
  git push
  echo "Pushed $current_branch to $upstream_ref"
else
  git push -u "$first_remote" "$current_branch"
  echo "Pushed $current_branch to $first_remote/$current_branch"
fi

echo "Done. New version: $new_version"
