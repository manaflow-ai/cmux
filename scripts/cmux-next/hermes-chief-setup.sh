#!/usr/bin/env bash
# Set up Hermes Agent (NousResearch/hermes-agent) as a Chief engine.
#
# usage: scripts/cmux-next/hermes-chief-setup.sh [--switch]
#
# 1. Installs Hermes with its ACP extra when `hermes` is not on PATH
#    (`uv tool install 'hermes-agent[acp]'`).
# 2. Checks its ACP server (`hermes acp --check`).
# 3. Makes sure acpmux lists the `hermes` harness: a new acpmux finds `hermes`
#    on PATH; an older one gets ~/.config/cmux/harnesses/hermes.toml, then
#    `acpmux harness reload`.
# 4. With --switch: sends Hermes one prompt (proof its provider and model
#    work), then runs `optchat-chief engine set --harness hermes`.
#
# The script never picks a provider, types a key or signs in. Do that once
# with `hermes model` (an API key such as OpenRouter or Anthropic, or a
# provider sign-in such as Nous Portal), then run this script with --switch.
# Switch back with `optchat-chief engine set --harness claude`.
set -euo pipefail

switch=0
for arg in "$@"; do
  case "$arg" in
    --switch) switch=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "hermes-chief-setup.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done

app_bin="/Applications/cmux NIGHTLY.app/Contents/Resources/bin"
acpmux="$(command -v acpmux || true)"
[[ -n "$acpmux" ]] || acpmux="$app_bin/acpmux"
chief="$(command -v optchat-chief || true)"
[[ -n "$chief" ]] || chief="$app_bin/optchat-chief"

if ! command -v hermes >/dev/null 2>&1; then
  command -v uv >/dev/null 2>&1 || { echo "Install uv first: https://docs.astral.sh/uv/" >&2; exit 1; }
  echo "Installing Hermes Agent with ACP support..."
  uv tool install 'hermes-agent[acp]'
fi
echo "Hermes: $(hermes --version 2>&1 | head -1)"
hermes acp --check

if ! "$acpmux" harness list 2>/dev/null | grep -qE '^hermes[[:space:]]'; then
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/cmux/harnesses"
  mkdir -p "$dir"
  if [[ ! -e "$dir/hermes.toml" ]]; then
    cat > "$dir/hermes.toml" <<'EOF'
# Hermes Agent (NousResearch/hermes-agent) speaks ACP itself: `hermes acp`.
# Pick its provider and model with `hermes model`.
schema = 1
id = "hermes"
name = "Hermes Agent"
icon = "hermes"
protocol = "acp"
command = "hermes"
args = ["acp"]

[capabilities]
permission_modes = true
resume = true

[auth]
login = "hermes model"
docs = "https://hermes-agent.nousresearch.com/docs/user-guide/features/acp"
EOF
    echo "Wrote $dir/hermes.toml"
  fi
  "$acpmux" harness reload || true
fi
"$acpmux" harness list | grep -E '^hermes[[:space:]]' || { echo "acpmux does not list hermes; see \`acpmux harness list\`" >&2; exit 1; }

if [[ "$switch" == 0 ]]; then
  echo
  echo "Next: run \`hermes model\` to pick a provider and model, then run this script with --switch."
  exit 0
fi

echo "Asking Hermes for one reply..."
reply="$(cd "${TMPDIR:-/tmp}" && hermes -z "Reply with the single word OK." 2>&1 | tail -1 || true)"
if [[ "$reply" != *OK* ]]; then
  echo "Hermes did not answer (\"$reply\"). Run \`hermes model\` first; the Chief engine was not changed." >&2
  exit 1
fi
"$chief" engine set --harness hermes
echo "The Chief now runs on Hermes. Switch back: $chief engine set --harness claude"
