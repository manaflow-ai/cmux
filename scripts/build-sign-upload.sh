#!/usr/bin/env bash
set -euo pipefail

# Queue stable publication through release.yml, the single serialized owner of the canonical R2
# appcast and GitHub's legacy /latest pointer. Nightly requests route through nightly.yml.

usage() {
  cat <<'EOF'
Usage: ./scripts/build-sign-upload.sh <tag> [--repair-appcast]

Options:
  --repair-appcast  Verify and republish an existing release's immutable appcast.

Normal stable publication creates/pushes the local tag when needed. An existing remote tag is
retried through the current default-branch release workflow. Nightly appcast-only repair is not
supported because nightly assets are rolling and mutable. Direct asset overwrite is unsupported.
EOF
}

REPAIR_APPCAST="false"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair-appcast)
      REPAIR_APPCAST="true"
      shift
      ;;
    --allow-overwrite)
      echo "ERROR: Signed release assets are immutable. Publish a new tag instead of overwriting." >&2
      exit 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

set -- "${POSITIONAL[@]}"
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

TAG="$1"
WORKFLOW_REF="${CMUX_RELEASE_WORKFLOW_REF:-main}"
for tool in gh git; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done

if [[ "$TAG" == "nightly" || "$TAG" == *"-nightly"* ]]; then
  if [[ "$TAG" != "nightly" ]]; then
    echo "ERROR: Nightly publication uses the rolling 'nightly' release." >&2
    exit 1
  fi
  if [[ "$REPAIR_APPCAST" == "true" ]]; then
    echo "ERROR: Nightly appcast-only repair is unsupported; rerun nightly publication without --repair-appcast." >&2
    exit 1
  fi
  gh workflow run nightly.yml --ref "$WORKFLOW_REF" --field force=true
  echo "Queued serialized nightly publication through .github/workflows/nightly.yml."
  exit 0
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Stable release tag must match v<major>.<minor>.<patch> exactly (got '$TAG')." >&2
  exit 1
fi

if [[ "$REPAIR_APPCAST" == "true" ]]; then
  if ! git ls-remote --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "ERROR: Cannot repair $TAG because the remote tag does not exist." >&2
    exit 1
  fi
  gh workflow run release.yml \
    --ref "$WORKFLOW_REF" \
    --field operation=publish-existing \
    --field release_tag="$TAG"
  echo "Queued serialized appcast repair for $TAG through .github/workflows/release.yml."
  exit 0
fi

if git ls-remote --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1; then
  gh workflow run release.yml \
    --ref "$WORKFLOW_REF" \
    --field operation=publish \
    --field release_tag="$TAG"
  echo "Queued serialized release retry for existing remote tag $TAG."
else
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Refusing to tag HEAD while tracked changes are uncommitted." >&2
    exit 1
  fi
  PROJECT_SNAPSHOT="$(mktemp)"
  if ! git show "HEAD:cmux.xcodeproj/project.pbxproj" > "$PROJECT_SNAPSHOT"; then
    rm -f "$PROJECT_SNAPSHOT"
    echo "ERROR: Could not read the committed Xcode project from HEAD." >&2
    exit 1
  fi
  if ! CMUX_PROJECT_FILE="$PROJECT_SNAPSHOT" ./scripts/validate-release-version.sh "$TAG"; then
    rm -f "$PROJECT_SNAPSHOT"
    echo "ERROR: Refusing to tag HEAD because its committed version does not match $TAG." >&2
    exit 1
  fi
  rm -f "$PROJECT_SNAPSHOT"
  if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    if [[ "$(git rev-list -n 1 "$TAG")" != "$(git rev-parse HEAD)" ]]; then
      echo "ERROR: Local tag $TAG does not point at the current release commit." >&2
      exit 1
    fi
  else
    git tag "$TAG"
  fi
  # The tag push is the authoritative release trigger. Do not dispatch a duplicate run.
  git push origin "refs/tags/$TAG"
  echo "Pushed $TAG; the serialized release workflow will build and publish it."
fi
