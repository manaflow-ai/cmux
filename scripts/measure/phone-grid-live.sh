#!/usr/bin/env bash
# phone-grid-live: a real Claude Code turn in a real cmux-tui daemon, then the Mac's pane and the
# phone's view of the same terminal (`agent-cli-phone-grid-v1`, drawn at the phone's own grid)
# side by side.
#
#   cmux-ci run --class exclusive --measurement --script scripts/measure/phone-grid-live.sh \
#     --ref SHA --artifact .build/phone-grid-live [--arg=grids=50x34,59x42] [--arg=claude=2.1.332] \
#     [--arg=route=http://HOST:PORT]
#
# route= is a Claude route that signs requests itself (the team subrouter), as team-eval.sh takes it;
# without it, Claude Code uses ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN from the environment.
#
# It builds cmux-tui and cmux-agent-cli-render's `phone_grid_proof` example from this checkout,
# installs the asked Claude Code version into a scratch folder (the host's own stays as it is),
# then runs scripts/agent-cli-render/phone_grid_live.py once per phone grid. Each grid's folder in
# .build/phone-grid-live holds mac.txt, phone.txt and side-by-side.html, and a typed/ folder for
# the same screen with an unsent draft.
set -euo pipefail
grids=50x34,59x42 claude=2.1.332 mac=110x32 route=""
for kv in "$@"; do
  case "$kv" in
    grids=*|claude=*|mac=*|route=*) eval "${kv%%=*}=\${kv#*=}";;
    *) echo "phone-grid-live: unknown argument $kv" >&2; exit 2;;
  esac
done
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out="$repo/.build/phone-grid-live"
mkdir -p "$out"
# A fleet Mac routes Claude Code through the team's model pool from its login environment.
if [ -z "${ANTHROPIC_BASE_URL:-}" ] && [ -f "$HOME/.zshenv" ]; then
  eval "$(grep -E '^export ANTHROPIC_[A-Z_]+=' "$HOME/.zshenv" || true)"
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/phone-grid-live.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
if npm install --silent --prefix "$work/claude" "@anthropic-ai/claude-code@$claude" >/dev/null 2>&1; then
  export PATH="$work/claude/node_modules/.bin:$PATH"
fi
command -v claude >/dev/null || { echo "phone-grid-live: no claude" >&2; exit 2; }
# Its own Claude home: the host's stays untouched, and no first-run theme picker.
export CLAUDE_CONFIG_DIR="$work/claude-home"
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"hasCompletedOnboarding": true, "theme": "dark"}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
# The pane's shell may not read the login environment: the model route goes in Claude's settings.
python3 -c 'import json, os, sys
route = sys.argv[2]
if route:
    settings = {"env": {"ANTHROPIC_BASE_URL": route},
                "apiKeyHelper": "echo sk-ant-placeholder-the-route-signs"}
else:
    keep = ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN")
    settings = {"env": {k: v for k, v in os.environ.items() if k in keep}}
json.dump(settings, open(sys.argv[1], "w"))' "$CLAUDE_CONFIG_DIR/settings.json" "$route"
chmod 600 "$CLAUDE_CONFIG_DIR/settings.json"
echo "claude: $(claude --version)"
cd "$repo/cmux-tui"
cargo build -q -p cmux-tui --bin cmux-tui
cargo build -q -p cmux-agent-cli-render --example phone_grid_proof
target=$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
IFS=, read -ra list <<<"$grids"
for grid in "${list[@]}"; do
  python3 "$repo/scripts/agent-cli-render/phone_grid_live.py" --bin "$target/debug" \
    --out "$out/$grid" --cols "${grid%x*}" --rows "${grid#*x}" --mac "$mac"
done
ls -R "$out"
