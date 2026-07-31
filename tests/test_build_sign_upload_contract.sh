#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

REMOTE_DIR="$FIXTURE_DIR/origin.git"
REPO_DIR="$FIXTURE_DIR/repo"
BIN_DIR="$FIXTURE_DIR/bin"
GH_LOG="$FIXTURE_DIR/gh.log"
mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/cmux.xcodeproj" "$BIN_DIR"

git init --bare -q "$REMOTE_DIR"
git init -q "$REPO_DIR"
git -C "$REPO_DIR" config user.name "Release Contract Test"
git -C "$REPO_DIR" config user.email "release-contract@example.com"
git -C "$REPO_DIR" config commit.gpgsign false
git -C "$REPO_DIR" remote add origin "$REMOTE_DIR"

cp "$ROOT_DIR/scripts/build-sign-upload.sh" "$REPO_DIR/scripts/build-sign-upload.sh"
cp "$ROOT_DIR/scripts/validate-release-version.sh" "$REPO_DIR/scripts/validate-release-version.sh"
printf '%s\n' \
  'MARKETING_VERSION = 1.2.3;' \
  'MARKETING_VERSION = 1.2.3;' \
  > "$REPO_DIR/cmux.xcodeproj/project.pbxproj"
git -C "$REPO_DIR" add scripts cmux.xcodeproj/project.pbxproj
git -C "$REPO_DIR" commit -qm "release fixture"
git -C "$REPO_DIR" branch -M main
git -C "$REPO_DIR" push -q -u origin main

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "%s\n" "$*" >> "$CMUX_TEST_GH_LOG"'
} > "$BIN_DIR/gh"
chmod +x "$BIN_DIR/gh"

run_wrapper() {
  (
    cd "$REPO_DIR"
    PATH="$BIN_DIR:$PATH" CMUX_TEST_GH_LOG="$GH_LOG" \
      ./scripts/build-sign-upload.sh "$@"
  )
}

# A new tag validates the committed project, pushes exactly once, and lets the tag push trigger CI.
run_wrapper v1.2.3 >/dev/null
git ls-remote --exit-code "$REMOTE_DIR" refs/tags/v1.2.3 >/dev/null
if [[ -s "$GH_LOG" ]]; then
  echo "FAIL: new tag push also dispatched a duplicate workflow" >&2
  exit 1
fi

# Existing-tag publication and repair execute current default-branch workflow code at the target tag.
run_wrapper v1.2.3 >/dev/null
run_wrapper v1.2.3 --repair-appcast >/dev/null
if ! grep -Fxq \
  'workflow run release.yml --ref main --field operation=publish --field release_tag=v1.2.3' \
  "$GH_LOG"; then
  echo "FAIL: existing release retry did not dispatch default-branch publish with release_tag" >&2
  exit 1
fi
if ! grep -Fxq \
  'workflow run release.yml --ref main --field operation=publish-existing --field release_tag=v1.2.3' \
  "$GH_LOG"; then
  echo "FAIL: appcast repair did not dispatch default-branch publish-existing with release_tag" >&2
  exit 1
fi

# An uncommitted version bump must never create an immutable tag for the old HEAD commit.
printf '%s\n' 'MARKETING_VERSION = 1.2.4;' > "$REPO_DIR/cmux.xcodeproj/project.pbxproj"
if run_wrapper v1.2.4 >/dev/null 2>&1; then
  echo "FAIL: uncommitted marketing version created a release tag" >&2
  exit 1
fi
if git ls-remote --exit-code "$REMOTE_DIR" refs/tags/v1.2.4 >/dev/null 2>&1; then
  echo "FAIL: mismatched committed release tag reached origin" >&2
  exit 1
fi

# Rolling nightly publication can rebuild, but cannot claim exact immutable appcast repair.
run_wrapper nightly >/dev/null
LINES_BEFORE_REPAIR="$(wc -l < "$GH_LOG" | tr -d ' ')"
if run_wrapper nightly --repair-appcast >/dev/null 2>&1; then
  echo "FAIL: nightly accepted unsupported appcast-only repair" >&2
  exit 1
fi
LINES_AFTER_REPAIR="$(wc -l < "$GH_LOG" | tr -d ' ')"
if [[ "$LINES_BEFORE_REPAIR" != "$LINES_AFTER_REPAIR" ]]; then
  echo "FAIL: rejected nightly repair still dispatched a workflow" >&2
  exit 1
fi
if ! grep -Fxq 'workflow run nightly.yml --ref main --field force=true' "$GH_LOG"; then
  echo "FAIL: normal nightly publication did not dispatch the serialized workflow" >&2
  exit 1
fi

echo "PASS: release wrapper dispatches current workflows and tags committed versions only"
