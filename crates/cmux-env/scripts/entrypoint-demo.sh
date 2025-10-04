#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the Docker demo image. Starts envd, prints docs, and
# launches an interactive shell (bash/zsh/fish) with envctl hooks installed.

TARGET_DIR="/usr/local/bin"
ENVD_BIN="$TARGET_DIR/envd"
ENVCTL_BIN="$TARGET_DIR/envctl"

if [[ ! -x "$ENVD_BIN" || ! -x "$ENVCTL_BIN" ]]; then
  echo "envd/envctl not found in $TARGET_DIR" >&2
  exit 1
fi

RUNTIME_DIR="/tmp/cmux-demo-$$"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR/cmux-envd"

"$ENVD_BIN" >/dev/null 2>&1 &
DAEMON_PID=$!

cleanup() {
  if kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$RUNTIME_DIR"
}
trap cleanup EXIT INT TERM

export PATH="$TARGET_DIR:$PATH"
export ENVCTL_GEN=0

cat <<'DOC'
=== cmux-env demo (Docker) ===

You are in a container with:
  - envd running per-user on a private runtime dir
  - envctl on PATH
  - shell hook installed to apply diffs on each prompt

Try these:
  envctl ping
  envctl status
  envctl set FOO=bar
  envctl export bash --since "${ENVCTL_GEN:-0}" --pwd "$PWD"
  envctl unset FOO

Directory-scoped overlay:
  mkdir -p demo/proj/sub && cd demo
  envctl set VAR=global
  envctl set VAR=local --dir "$PWD/proj"
  cd proj/sub   # prompt hook should export VAR=local
  cd ../..      # prompt hook should export VAR=global

Bulk load from stdin:
  printf "%s\n" "A=1" "B=2" | envctl load -
  envctl list

Note: Use literal keys. For example, 'envctl get FOO' not 'envctl get $FOO'.
Exit this shell to stop the daemon and container.
DOC

SHELL_KIND="${DEMO_SHELL:-bash}"
case "$SHELL_KIND" in
  bash)
    touch "$HOME/.bashrc"
    if ! grep -q '^export XDG_RUNTIME_DIR=' "$HOME/.bashrc" 2>/dev/null; then
      {
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
        echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
      } >> "$HOME/.bashrc"
    fi
    if ! grep -q "/usr/local/bin" "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="/usr/local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    "$ENVCTL_BIN" install-hook bash >/dev/null
    RCFILE="/tmp/envctl-bashrc.$$"
    {
      echo "# envctl demo rc"
      echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
      echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
      echo 'export PATH="/usr/local/bin:$PATH"'
      echo 'source "$HOME/.bashrc" >/dev/null 2>&1 || true'
    } > "$RCFILE"
    exec bash --noprofile --rcfile "$RCFILE" -i
    ;;
  zsh)
    touch "$HOME/.zshrc"
    if ! grep -q '^export XDG_RUNTIME_DIR=' "$HOME/.zshrc" 2>/dev/null; then
      {
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
        echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
      } >> "$HOME/.zshrc"
    fi
    if ! grep -q "/usr/local/bin" "$HOME/.zshrc" 2>/dev/null; then
      echo 'export PATH="/usr/local/bin:$PATH"' >> "$HOME/.zshrc"
    fi
    "$ENVCTL_BIN" install-hook zsh >/dev/null
    exec zsh -i
    ;;
  fish)
    mkdir -p "$HOME/.config/fish"
    CONFIG="$HOME/.config/fish/config.fish"
    touch "$CONFIG"
    if ! grep -q 'set -gx XDG_RUNTIME_DIR' "$CONFIG" 2>/dev/null; then
      echo 'set -gx XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"' >> "$CONFIG"
    fi
    if ! grep -q 'set -gx ENVCTL_GEN' "$CONFIG" 2>/dev/null; then
      echo 'set -gx ENVCTL_GEN 0' >> "$CONFIG"
    fi
    if ! grep -q "/usr/local/bin" "$CONFIG" 2>/dev/null; then
      echo 'set -gx PATH "/usr/local/bin" $PATH' >> "$CONFIG"
    fi
    "$ENVCTL_BIN" install-hook fish >/dev/null
    export XDG_CONFIG_HOME="$HOME/.config"
    exec fish -i
    ;;
  *)
    echo "Unknown DEMO_SHELL '$SHELL_KIND', falling back to bash." >&2
    touch "$HOME/.bashrc"
    if ! grep -q '^export XDG_RUNTIME_DIR=' "$HOME/.bashrc" 2>/dev/null; then
      {
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
        echo 'export ENVCTL_GEN=${ENVCTL_GEN:-0}'
      } >> "$HOME/.bashrc"
    fi
    if ! grep -q "/usr/local/bin" "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="/usr/local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    "$ENVCTL_BIN" install-hook bash >/dev/null
    exec bash -i
    ;;
esac
