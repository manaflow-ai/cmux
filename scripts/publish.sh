#!/bin/bash
set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure common dev ports are free (respect Chrome/OrbStack) using shared helper
CONVEX_PORT=${CONVEX_PORT:-9777}
PORTS_TO_CHECK="5173 $CONVEX_PORT 9777 9778"
source "$(dirname "$0")/_port-clean.sh"
clean_ports $PORTS_TO_CHECK


# Save current state
START_COMMIT=$(git rev-parse HEAD)
ORIGINAL_PACKAGE_JSON=""
VERSION_BUMPED=false
CHANGES_COMMITTED=false
CHANGES_PUSHED=false

# Function to print error messages
error() {
  echo -e "${RED}Error: $1${NC}" >&2
}

# Function to print success messages
success() {
  echo -e "${GREEN}✓ $1${NC}"
}

# Function to print warning messages
warning() {
  echo -e "${YELLOW}Warning: $1${NC}"
}

# Cleanup function to undo changes
undo() {
  echo ""
  warning "An error occurred. Rolling back changes..."
  
  # Reset git to original commit
  if [ "$CHANGES_PUSHED" = true ]; then
    error "Changes were already pushed to remote. Manual intervention required."
    echo "You may need to:"
    echo "  1. Create a revert commit: git revert HEAD"
    echo "  2. Force push (if allowed): git push --force-with-lease origin main"
  elif [ "$CHANGES_COMMITTED" = true ]; then
    echo "Resetting to original commit..."
    git reset --hard "$START_COMMIT"
    success "Git reset complete"
  fi
  
  # Restore original package.json if version was bumped but not committed
  if [ "$VERSION_BUMPED" = true ] && [ "$CHANGES_COMMITTED" = false ] && [ -n "$ORIGINAL_PACKAGE_JSON" ]; then
    echo "Restoring original package.json..."
    echo "$ORIGINAL_PACKAGE_JSON" > packages/cmux/package.json
    success "package.json restored"
  fi
  
  # Clean any untracked files created during the process
  echo "Cleaning untracked files..."
  git clean -fd
  success "Cleanup complete"
  
  error "Publish process failed and has been rolled back"
  exit 1
}

# Set up error trap
trap undo ERR

# Additional trap for SIGINT (Ctrl+C)
trap 'error "Process interrupted by user"; undo' INT

echo "Starting publish process..."

# Step 0: Check Docker authentication by attempting to pull a small test image
echo "Checking Docker Hub authentication..."
if ! docker pull alpine:latest >/dev/null 2>&1; then
  error "Unable to pull from Docker Hub. Please run 'docker login' first."
  exit 1
fi

# Also check if config.json exists with auth
if [ ! -f ~/.docker/config.json ] || ! grep -q '"auths"' ~/.docker/config.json 2>/dev/null; then
  warning "Docker config not found or incomplete. You may have issues pushing."
fi

success "Docker Hub connectivity verified"

# Step 1: Check for uncommitted changes
echo "Checking git status..."
git update-index -q --refresh
if ! git diff-index --quiet HEAD --; then
  error "You have uncommitted changes. Please commit or stash them before running this script."
  echo "Run 'git status' to see what has changed."
  exit 1
fi
success "Working directory is clean"

# Step 2: Check current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
  error "You must be on the 'main' branch to publish. Current branch: $CURRENT_BRANCH"
  exit 1
fi
success "On main branch"

# Step 3: Ensure we're up to date with remote
echo "Fetching latest from remote..."
git fetch origin main
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
  error "Your local main branch is not up to date with origin/main"
  echo "Run 'git pull origin main' to update"
  exit 1
fi
success "Local branch is up to date with remote"

# Step 4: Save current package.json for potential rollback
ORIGINAL_PACKAGE_JSON=$(cat packages/cmux/package.json)
CURRENT_VERSION=$(node -p "require('./packages/cmux/package.json').version")
echo "Current version: v$CURRENT_VERSION"

# Step 5: Bump version
echo "Bumping version..."
npm version patch --no-git-tag-version --prefix packages/cmux
VERSION_BUMPED=true
NEW_VERSION=$(node -p "require('./packages/cmux/package.json').version")
success "Version bumped to v$NEW_VERSION"

# Run typecheck

bun run typecheck

# Step 6: Build CLI and Docker image
echo "Building CLI..."
echo "----------------------------------------"
./scripts/build-cli.ts
if [ $? -ne 0 ]; then
  error "CLI build failed"
  exit 1
fi
success "CLI build complete"

echo ""
echo "Building and pushing Docker image..."
echo "----------------------------------------"
# Use simple push script to work around OrbStack issues
./scripts/docker-push-simple.sh "$NEW_VERSION"
# Don't fail on Docker push issues as they're often transient with OrbStack
if [ $? -ne 0 ]; then
  warning "Docker push had issues (common with OrbStack)"
  warning "You may need to manually push later: docker push ghcr.io/manaflow-ai/cmux:$NEW_VERSION"
else
  success "Docker build and push complete"
fi

# Step 7: Commit changes
echo "Committing changes..."
git add -A
git commit -m "v$NEW_VERSION"
CHANGES_COMMITTED=true
success "Changes committed"

# Step 8: Push to main
echo "Pushing to origin/main..."
git push origin main
CHANGES_PUSHED=true
success "Changes pushed to remote"

# Step 9: Publish to npm
echo "Publishing to npm..."
(cd packages/cmux && npm run publish-cli)
success "Published to npm"

# Clear trap since we succeeded
trap - ERR INT

echo ""
success "🎉 Successfully published cmux v$NEW_VERSION to npm!"
echo ""
echo "Next steps:"
echo "  - Verify the package on npm: https://www.npmjs.com/package/cmux"
echo "  - Test installation: npm install -g cmux@$NEW_VERSION"
echo "  - Verify Docker image: docker pull ghcr.io/manaflow-ai/cmux:$NEW_VERSION"
