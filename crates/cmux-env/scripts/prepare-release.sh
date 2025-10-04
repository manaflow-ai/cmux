#!/usr/bin/env bash
set -euo pipefail

# Prepare and execute a release with all necessary checks
# Usage: scripts/prepare-release.sh <version>

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/prepare-release.sh <version>" >&2
  echo "  e.g.: scripts/prepare-release.sh 0.0.3" >&2
  exit 1
fi

here_dir() { cd -- "$(dirname -- "$0")/.." && pwd; }
ROOT_DIR="$(here_dir)"
cd "$ROOT_DIR"

echo "🔍 Pre-release checks for v$VERSION"
echo "====================================="

# 1. Check if we're on main branch
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" != "main" ]]; then
  echo "⚠️  Warning: Not on main branch (current: $current_branch)"
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# 2. Pull latest changes
echo "📥 Pulling latest changes from origin/main..."
git pull origin main --ff-only || {
  echo "⚠️  Could not fast-forward pull. Please resolve conflicts first."
  exit 1
}

# 3. Run tests
echo "🧪 Running tests..."
if cargo test --quiet; then
  echo "✅ Tests passed"
else
  echo "❌ Tests failed. Please fix before releasing."
  exit 1
fi

# 4. Check current Cargo.toml version
current_ver=$(grep -m1 '^version *= *"' Cargo.toml | sed -E 's/.*"([^"]+)".*/\1/')
echo "📦 Current Cargo.toml version: $current_ver"
echo "🎯 Target release version: $VERSION"

if [[ "$current_ver" != "$VERSION" ]]; then
  echo "📝 Updating Cargo.toml to $VERSION..."
  sed -i.bak "s/^version = \".*\"/version = \"$VERSION\"/" Cargo.toml
  rm -f Cargo.toml.bak

  # Build to verify it compiles with new version
  echo "🔨 Building to verify version update..."
  cargo build --release --quiet

  # Commit the version change (including Cargo.lock)
  git add Cargo.toml Cargo.lock
  git commit -m "chore: bump version to $VERSION"
  echo "✅ Version updated and committed"
else
  echo "✅ Version already matches"
fi

# 5. Push any commits to main
echo "📤 Pushing commits to main..."
git push origin main

# 6. Now run the release script
echo ""
echo "🚀 Starting release process..."
echo "====================================="
exec scripts/release.sh "$VERSION"