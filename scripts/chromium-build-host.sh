#!/usr/bin/env bash
# chromium-build-host.sh
#
# Idempotent bootstrap for the cmux Chromium fork build host.
# Designed to be re-runnable: each step skips its work if already done.
#
# Run from a workstation:
#   ./scripts/chromium-build-host.sh setup
#
# Run from the host itself (ssh cmux-aws-mac, then):
#   ./chromium-build-host.sh setup
#
# Subcommands:
#   setup            Mount Chromium volume, install depot_tools, sync .zshrc.
#   remount          Just re-attach the Chromium APFS volume (after reboot).
#   fetch            Begin or resume Chromium fetch (Mac-only, shallow).
#   status           Report build host state (depot_tools, fetch progress).
#   build [target]   Run a release build (default target: cmux_core_framework).
#
# Constants — see plans/chromium-engine.md for rationale.

set -euo pipefail

# Build host alias (in ~/.ssh/config).
readonly REMOTE_HOST="${CMUX_BUILD_HOST:-cmux-aws-mac}"

# Path on the build host where the Chromium fork lives.
# We use /Users/ec2-user/chromium-fork (a NEW path, not the existing
# /Users/ec2-user/chromium which has prior unrelated work). The /Volumes
# layout on this Mac is a topic in plans/chromium-engine.md.
readonly REMOTE_CHROMIUM_ROOT="/Users/ec2-user/chromium-fork"
readonly REMOTE_DEPOT_TOOLS="/Users/ec2-user/depot_tools"

# Chromium release branch to track. Update when promoting to a new
# milestone; record the change in plans/chromium-engine-handoff.md.
readonly CHROMIUM_BRANCH="refs/branch-heads/7204"   # M148 stable
readonly CHROMIUM_SRC_URL="https://chromium.googlesource.com/chromium/src.git"

usage() {
    cat <<EOF
$(basename "$0") <setup|remount|fetch|status|build [target]>

Targets the build host CMUX_BUILD_HOST=${REMOTE_HOST} via ssh.

Examples:
    $(basename "$0") setup
    $(basename "$0") status
    $(basename "$0") fetch
    $(basename "$0") build cmux_core_framework
EOF
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
fi

run_remote() {
    ssh -o BatchMode=yes "${REMOTE_HOST}" "$@"
}

cmd_setup() {
    echo ">> Ensuring depot_tools on ${REMOTE_HOST}"
    run_remote bash <<EOS
set -euo pipefail
if [ ! -d "${REMOTE_DEPOT_TOOLS}" ]; then
    git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "${REMOTE_DEPOT_TOOLS}"
else
    echo "  depot_tools present, skipping clone"
fi

# Fix .zshrc ownership (was created root-owned on this AMI).
if [ -f /Users/ec2-user/.zshrc ] && [ "\$(stat -f %u /Users/ec2-user/.zshrc)" != "501" ]; then
    sudo -n chown ec2-user:staff /Users/ec2-user/.zshrc
fi

# Add depot_tools to PATH idempotently.
if ! grep -q "depot_tools" /Users/ec2-user/.zshrc 2>/dev/null; then
    cat >> /Users/ec2-user/.zshrc <<'ZRC'

# cmux Chromium fork build host (managed by scripts/chromium-build-host.sh)
export PATH="\$HOME/depot_tools:\$PATH"
export DEPOT_TOOLS_UPDATE=1
export VPYTHON_BYPASS="manually managed python not supported by chrome operations"
ZRC
fi

mkdir -p "${REMOTE_CHROMIUM_ROOT}"
echo ">> Setup done. depot_tools=\$(which gclient 2>/dev/null || echo missing)"
EOS
}

cmd_remount() {
    # No-op today: the cmux Chromium fork lives under /Users/ec2-user
    # which is on the persistent data volume. Reserved for the case
    # where a future host moves the checkout to an APFS volume mounted
    # at /Volumes/Chromium (see plans/chromium-engine.md "Build host
    # plan" for context).
    echo ">> No volume to remount (using /Users/ec2-user). No-op."
}

cmd_fetch() {
    echo ">> Beginning Chromium fetch in ${REMOTE_CHROMIUM_ROOT}"
    run_remote bash <<EOS
set -euo pipefail
export PATH="${REMOTE_DEPOT_TOOLS}:\$PATH"
cd "${REMOTE_CHROMIUM_ROOT}"

if [ ! -f .gclient ]; then
    cat > .gclient <<'GCLIENT'
solutions = [
  {
    "name": "src",
    "url": "${CHROMIUM_SRC_URL}",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
        "checkout_pgo_profiles": False
    },
  },
]
target_os = ['mac']
GCLIENT
    echo "  wrote .gclient (mac-only, no PGO)"
fi

if [ ! -d src ]; then
    echo "  cloning src/ shallow at ${CHROMIUM_BRANCH}"
    git clone --depth=1 --branch=main "${CHROMIUM_SRC_URL}" src
fi

cd src
git fetch --depth=1 origin "${CHROMIUM_BRANCH}"
git checkout FETCH_HEAD

cd ..
echo "  running gclient sync (this is hours)"
exec nohup gclient sync --no-history --shallow -j 16 > "${REMOTE_CHROMIUM_ROOT}/gclient-sync.log" 2>&1 &
echo "  fetch pid: \$!"
echo "  log: ${REMOTE_CHROMIUM_ROOT}/gclient-sync.log"
EOS
}

cmd_status() {
    run_remote bash <<EOS
set -euo pipefail
echo "== build host: ${REMOTE_HOST} =="
sw_vers | head -2
echo "-- disk --"
df -h /Users/ec2-user 2>/dev/null
echo "-- depot_tools --"
if command -v "${REMOTE_DEPOT_TOOLS}/gclient" >/dev/null 2>&1; then
    "${REMOTE_DEPOT_TOOLS}/gclient" --version 2>&1 | head -1
else
    echo "  not installed"
fi
echo "-- chromium fork --"
if [ -d "${REMOTE_CHROMIUM_ROOT}/src" ]; then
    cd "${REMOTE_CHROMIUM_ROOT}/src"
    echo "  HEAD: \$(git rev-parse --short HEAD)"
    echo "  size: \$(du -sh . 2>/dev/null | awk '{print \$1}')"
else
    echo "  not fetched"
fi
echo "-- sync in flight --"
if pgrep -fl 'gclient' >/dev/null 2>&1; then
    pgrep -fl 'gclient' | head -3
else
    echo "  none"
fi
echo "-- last sync log --"
if [ -f "${REMOTE_CHROMIUM_ROOT}/gclient-sync.log" ]; then
    tail -5 "${REMOTE_CHROMIUM_ROOT}/gclient-sync.log"
else
    echo "  no log yet"
fi
EOS
}

cmd_build() {
    local target="${1:-cmux_core_framework}"
    local out_dir="out/cmux_release"
    echo ">> Building target ${target} in ${out_dir}"
    run_remote bash <<EOS
set -euo pipefail
export PATH="${REMOTE_DEPOT_TOOLS}:\$PATH"
cd "${REMOTE_CHROMIUM_ROOT}/src"

if [ ! -f "${out_dir}/args.gn" ]; then
    mkdir -p "${out_dir}"
    cat > "${out_dir}/args.gn" <<'ARGS'
# cmux Chromium fork release args
is_debug = false
is_component_build = false
symbol_level = 1
target_cpu = "arm64"
target_os = "mac"
enable_nacl = false
proprietary_codecs = true
ffmpeg_branding = "Chrome"
# CmuxCore framework target: see //cmux/embedder
is_chrome_branded = false
chrome_pgo_phase = 0
ARGS
    gn gen "${out_dir}"
fi

autoninja -C "${out_dir}" "${target}"
EOS
}

case "$1" in
    setup)   cmd_setup ;;
    remount) cmd_remount ;;
    fetch)   cmd_fetch ;;
    status)  cmd_status ;;
    build)   shift; cmd_build "$@" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
