#!/usr/bin/env bash
set -euo pipefail

# Release helper using GitHub CLI.
# - Tags current HEAD with vX.Y.Z
# - Pushes tag to origin
# - Waits for release assets (Linux x86_64/aarch64 MUSL) to appear
# - Verifies install.sh raw URL matches local file

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh (GitHub CLI) not found" >&2
  exit 1
fi

here_dir() { cd -- "$(dirname -- "$0")/.." && pwd; }
ROOT_DIR="$(here_dir)"
cd "$ROOT_DIR"

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version>" >&2
  echo "  version: semantic version (e.g., 0.0.3)" >&2
  exit 1
fi

# Ensure Cargo.toml version matches
manifest_ver=$(grep -m1 '^version *= *"' Cargo.toml | sed -E 's/.*"([^"]+)".*/\1/')
if [[ "$manifest_ver" != "$VERSION" ]]; then
  echo "📝 Updating Cargo.toml version from $manifest_ver to $VERSION..."
  sed -i.bak "s/^version = \".*\"/version = \"$VERSION\"/" Cargo.toml
  rm -f Cargo.toml.bak
  git add Cargo.toml
  git commit -m "chore: bump version to $VERSION" || {
    echo "warning: no changes to commit (version might already be correct)" >&2
  }
else
  echo "✅ Cargo.toml version already matches $VERSION"
fi

tag="v${VERSION}"

# Check for uncommitted changes other than Cargo.toml
if git diff-index HEAD -- | grep -v Cargo.toml | grep -q .; then
  echo "error: working tree has uncommitted changes besides Cargo.toml" >&2
  echo "hint: commit or stash your changes first" >&2
  exit 1
fi

echo "🏷️  Creating release tag $tag..."

# Create tag and push
if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "⚠️  Tag $tag already exists locally"
  read -p "Delete and recreate tag? (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    git tag -d "$tag"
    git push origin :refs/tags/"$tag" 2>/dev/null || true
    git tag -a "$tag" -m "Release $tag"
  else
    echo "Proceeding with existing tag"
  fi
else
  git tag -a "$tag" -m "Release $tag"
fi

echo "🚀 Pushing tag to origin..."
git push origin "$tag"

# Wait for release assets via gh release view (avoids plumbing with workflow runs)
echo "⏳ Waiting for GitHub Actions to build release assets..."
echo "   (This triggers the release workflow at .github/workflows/release.yml)"
assets_needed=(
  "cmux-env-${VERSION}-x86_64-unknown-linux-musl.tar.gz"
  "cmux-env-${VERSION}-aarch64-unknown-linux-musl.tar.gz"
)

deadline=$((SECONDS + 900)) # 15 minutes
while (( SECONDS < deadline )); do
  # shellcheck disable=SC2312
  json=$(gh release view "$tag" --json assets -q .assets[]?.name 2>/dev/null || true)
  ok=1
  for a in "${assets_needed[@]}"; do
    if ! grep -q "$a" <<<"$json"; then ok=0; break; fi
  done
  if (( ok == 1 )); then
    echo "All assets are uploaded."
    break
  fi
  echo "  - still waiting..."
  sleep 10
done

if (( SECONDS >= deadline )); then
  echo "error: timed out waiting for release assets" >&2
  exit 1
fi

# Verify install.sh is live on main and matches local content
raw_url="https://raw.githubusercontent.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/main/scripts/install.sh"
echo "Verifying install URL: $raw_url"
local_sha=$(sha256sum scripts/install.sh | awk '{print $1}')
remote_tmp=$(mktemp)
trap 'rm -f "$remote_tmp"' EXIT
curl -fsSL "$raw_url" -o "$remote_tmp"
remote_sha=$(sha256sum "$remote_tmp" | awk '{print $1}')

if [[ "$local_sha" != "$remote_sha" ]]; then
  echo "warning: install.sh on main does not match local copy" >&2
  echo "  local:  $local_sha" >&2
  echo "  remote: $remote_sha" >&2
  echo "Note: Did you push the latest changes to main?" >&2
else
  echo "install.sh verified: remote content matches local file."
fi

echo ""
echo "✅ Release $tag is ready!"
echo ""
echo "📦 Install with:"
echo "  curl -fsSL $raw_url | bash"
echo ""
echo "🔗 GitHub Release: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$tag"

