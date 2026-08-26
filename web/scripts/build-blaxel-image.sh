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

# --name is required: bl push names the image after the directory ("blaxel")
# otherwise, ignoring the name in blaxel.toml.
bl push -t sandbox -d "$template_dir" -n cmux-devbox -y "$@"

echo
echo "Published. Resolve the image id with:"
echo "  bl get image sandbox/cmux-devbox --latest"
echo "Then validate a machine with BLAXEL_SANDBOX_IMAGE=sandbox/cmux-devbox:latest"
echo "and record the result in web/services/vms/images/manifest.json."
