#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: build-sprite-base.sh [options]' \
    '' \
    'Build a credential-free Fly Sprite checkpoint containing a pinned cmux remote' \
    'daemon service.' \
    '' \
    'Options:' \
    '  --org <slug>             Sprite organization (default: SPRITE_ORG or manaflow)' \
    '  --name <name>            Base Sprite name (default: cmux-tui-base-<timestamp>)' \
    '  --cmux-version <version> Pinned npm cmux version (default: 0.9.11)' \
    '  --keep-running           Start the daemon after creating the clean checkpoint' \
    '  --keep-on-failure        Do not destroy a newly created Sprite after failure' \
    '  -h, --help               Show this help' \
    '' \
    'Authentication:' \
    '  Source an owner-only file that exports SPRITE_TOKEN before running. The token' \
    '  is used only by the local Sprite CLI and is never copied into the Sprite or' \
    '  checkpoint.'
}

org="${SPRITE_ORG:-manaflow}"
name=""
cmux_version="0.9.11"
keep_running=0
keep_on_failure=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)
      org="${2:?missing value for --org}"
      shift 2
      ;;
    --name)
      name="${2:?missing value for --name}"
      shift 2
      ;;
    --cmux-version)
      cmux_version="${2:?missing value for --cmux-version}"
      shift 2
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    --keep-on-failure)
      keep_on_failure=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$cmux_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "--cmux-version must be an exact semver version" >&2
  exit 2
fi
if [[ -z "${SPRITE_TOKEN:-}" ]]; then
  echo "SPRITE_TOKEN is required" >&2
  exit 2
fi
if ! command -v sprite >/dev/null 2>&1; then
  echo "sprite CLI is required: curl -fsSL https://sprites.dev/install.sh | bash" >&2
  exit 2
fi

if [[ -z "$name" ]]; then
  name="cmux-tui-base-$(date -u +%Y%m%d-%H%M%S)"
fi
if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "--name must contain lowercase letters, digits, and hyphens" >&2
  exit 2
fi

created=0
cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && "$created" -eq 1 && "$keep_on_failure" -eq 0 ]]; then
    sprite destroy -o "$org" -s "$name" --force >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

sprite create -o "$org" --skip-console "$name"
created=1

# The Sprite edge is only the carrier. cmux authenticates and encrypts every
# connection with Noise and an enrolled device key. No Sprite management token
# or static cmux token is embedded in the image.
sprite url update -o "$org" -s "$name" --auth public

sprite exec -o "$org" -s "$name" -- bash -lc "
  set -euo pipefail
  npm install -g --omit=dev --no-audit --fund=false 'cmux@${cmux_version}'
  sudo ln -sf \"\$(npm prefix -g)/bin/cmux\" /usr/local/bin/cmux
  /usr/local/bin/cmux --version
  install -d -m 700 /home/sprite/.local/share/cmux-sprite
  sprite-env services create cmux-tui \
    --cmd /usr/local/bin/cmux \
    --args daemon,--session,sprite,--remote-ws,0.0.0.0:8080,--remote-ws-insecure-bind,--remote-state-dir,/home/sprite/.local/share/cmux-sprite/remote \
    --dir /home/sprite \
    --http-port 8080 \
    --duration 10s
  sprite-env services stop cmux-tui
  rm -rf /home/sprite/.local/share/cmux-sprite/remote /tmp/cmux-tui-*
  rm -f /.sprite/logs/services/cmux-tui.log
  install -d -m 700 /home/sprite/.local/share/cmux-sprite
  test ! -e /home/sprite/.local/share/cmux-sprite/remote
"

checkpoint_output="$(
  sprite checkpoint create -o "$org" -s "$name" \
    --comment "cmux ${cmux_version} clean base; no daemon identity, invitations, or credentials"
)"
printf '%s\n' "$checkpoint_output"
checkpoint="$(
  printf '%s\n' "$checkpoint_output" |
    awk '/Checkpoint v[0-9]+ created/ { for (i = 1; i <= NF; i++) if ($i ~ /^v[0-9]+$/) print $i }' |
    tail -1
)"
if [[ -z "$checkpoint" ]]; then
  echo "checkpoint creation returned no checkpoint id" >&2
  exit 1
fi

if [[ "$keep_running" -eq 1 ]]; then
  sprite exec -o "$org" -s "$name" -- sprite-env services start cmux-tui
fi

trap - EXIT
printf '\nSPRITE_BASE_ORG=%s\n' "$org"
printf 'SPRITE_BASE_NAME=%s\n' "$name"
printf 'SPRITE_BASE_CHECKPOINT=%s\n' "$checkpoint"
printf 'SPRITE_BASE_CMUX_VERSION=%s\n' "$cmux_version"
printf 'SPRITE_BASE_DAEMON_STATE=absent\n'
printf 'SPRITE_BASE_SERVICE=%s\n' "$([[ "$keep_running" -eq 1 ]] && echo running || echo stopped)"
