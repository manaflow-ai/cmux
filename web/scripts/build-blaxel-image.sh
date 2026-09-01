#!/usr/bin/env bash
# Builds and publishes the baked Blaxel machine image (sandbox/cmux-devbox) on
# Blaxel's remote builder. No local docker needed; the Blaxel CLI uploads the
# template directory and streams the build.
#
#   web/scripts/build-blaxel-image.sh            # build + publish image only
#   web/scripts/build-blaxel-image.sh --skip-build
#
# After a successful bake, create a machine with BLAXEL_SANDBOX_IMAGE set to the
# printed image id, validate it (terminal, agents, desktop on 6901), and update
# web/services/vms/images/manifest.json.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_dir="$script_dir/../services/vms/images/blaxel"

command -v bl >/dev/null 2>&1 || { echo "blaxel CLI (bl) not installed" >&2; exit 127; }

# Run from inside the template directory. `bl push -d <dir>` resolves blaxel.toml
# from <dir> but packages the CALLER's cwd as the build context: invoked from the
# repo root it uploads the monorepo, finds no Dockerfile there, sees the root
# package.json, and silently generates a Node app image instead of building this
# template (measured 2026-08-26). --name is also required: the CLI otherwise
# names the image after the directory, ignoring blaxel.toml.
cd "$template_dir"
bl push -t sandbox -n cmux-devbox -y "$@"

echo
echo "Published. Resolve the image id with:"
echo "  bl get image sandbox/cmux-devbox --latest"
echo "Then validate a machine with BLAXEL_SANDBOX_IMAGE=sandbox/cmux-devbox:latest"
echo "and record the result in web/services/vms/images/manifest.json."
