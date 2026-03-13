#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INTEGRATION_DIR="$PROJECT_DIR/Resources/shell-integration"
DEFAULT_GHOSTTY_RESOURCES_DIR="$PROJECT_DIR/ghostty/src"

PROVIDER_PRESET="none"
OVERRIDE_PROVIDER=""
ONCE=0
KEEP_TEMP=0

usage() {
  cat <<'EOF'
Usage: ./scripts/probe-terminal-autosuggestions.sh [options]

Launch an isolated nested zsh in the current cmux panel without loading your real
~/.zshrc. The nested shell reports its autosuggestion provider to the current
panel so you can inspect the result through `cmux sidebar-state`.

Options:
  --provider <preset>    Simulate a provider in the isolated .zshrc.
                         Presets: none, zsh-autosuggestions, zsh-autocomplete, unknown
                         Default: none
  --override <provider>  Set CMUX_AUTOSUGGEST_PROVIDER_OVERRIDE for the nested shell.
                         Examples: none, cmux, external:unknown
  --once                 Print autosuggestion sidebar state and exit.
  --keep-temp            Keep the temporary ZDOTDIR directory for inspection.
  -h, --help             Show this help.

Examples:
  ./scripts/probe-terminal-autosuggestions.sh
  ./scripts/probe-terminal-autosuggestions.sh --provider zsh-autosuggestions --once
  ./scripts/probe-terminal-autosuggestions.sh --provider zsh-autocomplete
  ./scripts/probe-terminal-autosuggestions.sh --provider unknown --override none --once
EOF
}

require_cmux_panel() {
  if [[ -z "${CMUX_TAB_ID:-}" || -z "${CMUX_PANEL_ID:-}" ]]; then
    echo "error: run this from a cmux terminal panel so the nested shell can report back to the active panel" >&2
    exit 1
  fi
}

validate_provider_preset() {
  case "$1" in
    none|zsh-autosuggestions|zsh-autocomplete|unknown)
      ;;
    *)
      echo "error: unsupported --provider preset '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
}

provider_marker_block() {
  case "$1" in
    none)
      ;;
    zsh-autosuggestions)
      cat <<'EOF'
typeset -g ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
EOF
      ;;
    zsh-autocomplete)
      cat <<'EOF'
function _autocomplete__main() { :; }
EOF
      ;;
    unknown)
      cat <<'EOF'
function _custom_autosuggest_preview() { :; }
EOF
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      PROVIDER_PRESET="${2:-}"
      if [[ -z "$PROVIDER_PRESET" ]]; then
        echo "error: --provider requires a value" >&2
        exit 1
      fi
      validate_provider_preset "$PROVIDER_PRESET"
      shift 2
      ;;
    --override)
      OVERRIDE_PROVIDER="${2:-}"
      if [[ -z "$OVERRIDE_PROVIDER" ]]; then
        echo "error: --override requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmux_panel

if [[ ! -d "$INTEGRATION_DIR" ]]; then
  echo "error: missing shell integration directory at $INTEGRATION_DIR" >&2
  exit 1
fi

GHOSTTY_RESOURCES_DIR="${GHOSTTY_RESOURCES_DIR:-$DEFAULT_GHOSTTY_RESOURCES_DIR}"
if [[ ! -d "$GHOSTTY_RESOURCES_DIR" ]]; then
  echo "error: missing Ghostty resources directory at $GHOSTTY_RESOURCES_DIR" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-autosuggest-probe.XXXXXX")"
cleanup() {
  if [[ "$KEEP_TEMP" -eq 1 ]]; then
    echo "kept temporary ZDOTDIR at $TMP_ROOT"
    return
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$TMP_ROOT/.zshenv" <<'EOF'

EOF

cat > "$TMP_ROOT/.zshrc" <<EOF
export HISTFILE="$TMP_ROOT/.zsh_history"
SAVEHIST=0
HISTSIZE=0
PROMPT='autosuggest-probe(${PROVIDER_PRESET}) %1~ %# '

cmux_autosuggest_state() {
    if ! command -v cmux >/dev/null 2>&1; then
        print -r -- 'cmux CLI not found in PATH'
        return 1
    fi

    local output
    if ! output="\$(cmux sidebar-state 2>/dev/null)"; then
        print -r -- 'Failed to read sidebar state. Make sure this shell is running inside the tagged cmux build.'
        return 1
    fi

    if command -v rg >/dev/null 2>&1; then
        print -r -- "\$output" | rg '^autosuggestion_'
    else
        print -r -- "\$output" | grep '^autosuggestion_'
    fi
}

alias cas='cmux_autosuggest_state'

print -P "%F{cyan}[cmux autosuggest probe]%f isolated zshrc active"
print -P "%F{cyan}[cmux autosuggest probe]%f preset=${PROVIDER_PRESET}"
if [[ -n "${OVERRIDE_PROVIDER}" ]]; then
    print -P "%F{cyan}[cmux autosuggest probe]%f override=${OVERRIDE_PROVIDER}"
fi
print -P "%F{cyan}[cmux autosuggest probe]%f run 'cas' to inspect sidebar autosuggestion state"
EOF

provider_marker_block "$PROVIDER_PRESET" >> "$TMP_ROOT/.zshrc"

if [[ "$ONCE" -eq 1 ]]; then
  env_args=(
    ZDOTDIR="$INTEGRATION_DIR"
    CMUX_ZSH_ZDOTDIR="$TMP_ROOT"
    CMUX_SHELL_INTEGRATION=1
    CMUX_SHELL_INTEGRATION_DIR="$INTEGRATION_DIR"
    GHOSTTY_RESOURCES_DIR="$GHOSTTY_RESOURCES_DIR"
  )
  if [[ -n "$OVERRIDE_PROVIDER" ]]; then
    env_args+=(CMUX_AUTOSUGGEST_PROVIDER_OVERRIDE="$OVERRIDE_PROVIDER")
  fi

  env "${env_args[@]}" /bin/zsh -i -c '_cmux_report_autosuggestion_provider; sleep 0.2; cmux_autosuggest_state'
  exit 0
fi

echo "Launching isolated nested zsh. Exit it to return to your normal shell."
env_args=(
  ZDOTDIR="$INTEGRATION_DIR"
  CMUX_ZSH_ZDOTDIR="$TMP_ROOT"
  CMUX_SHELL_INTEGRATION=1
  CMUX_SHELL_INTEGRATION_DIR="$INTEGRATION_DIR"
  GHOSTTY_RESOURCES_DIR="$GHOSTTY_RESOURCES_DIR"
)
if [[ -n "$OVERRIDE_PROVIDER" ]]; then
  env_args+=(CMUX_AUTOSUGGEST_PROVIDER_OVERRIDE="$OVERRIDE_PROVIDER")
fi

env "${env_args[@]}" /bin/zsh -i
