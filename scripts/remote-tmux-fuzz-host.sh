#!/bin/bash
# Stand up (or restart) the local ssh host that the remote-tmux harnesses
# drive: a loopback-only sshd whose logins land in an isolated tmux server.
# Everything the harnesses call "remote" — ssh, tmux control mode, the
# mirror connection — runs against 127.0.0.1 with generated keys, so the
# repro and fuzz scripts work on any machine with no real network, no MFA,
# and no risk to the user's own tmux server.
#
# The sshd caps itself at one session (MaxSessions 1), matching hosts that
# limit concurrent ssh sessions — the constrained regime remote-tmux has to
# handle by sharing a single connection. The forced command in
# authorized_keys pins TMUX_TMPDIR to this host's own directory, so its
# tmux server can be created and killed freely without ever touching the
# default tmux socket.
#
# Usage: scripts/remote-tmux-fuzz-host.sh [name] [port]
# Then add the printed Host block to ~/.ssh/config (the app resolves the
# alias from there), and run e.g.:
#   CMUX_TAG=<tag> scripts/remote-tmux-live-fuzz.sh <name> 1 25
set -eu

NAME="${1:-cmux-fuzzhost}"
PORT="${2:-2296}"
case "$NAME" in
  ''|*[!A-Za-z0-9._-]*) echo "invalid host name: $NAME" >&2; exit 2 ;;
esac
case "$PORT" in
  ''|*[!0-9]*) echo "invalid port: $PORT" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "port out of range: $PORT" >&2
  exit 2
fi

umask 077
STATE_ROOT="$HOME/Library/Caches/cmux/remote-tmux-fuzz"
DIR="$STATE_ROOT/${NAME}-sshd"
TMUX_DIR="$STATE_ROOT/${NAME}-tmux"
if [ -L "$STATE_ROOT" ] || [ -L "$DIR" ] || [ -L "$TMUX_DIR" ]; then
  echo "refusing symlinked fuzz-host state path" >&2
  exit 1
fi

mkdir -p "$STATE_ROOT" "$DIR" "$TMUX_DIR"
chmod 700 "$STATE_ROOT" "$DIR" "$TMUX_DIR"
[ -f "$DIR/hostkey" ] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/hostkey"
[ -f "$DIR/clientkey" ] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/clientkey"

cat > "$DIR/wrap.sh" <<EOF
#!/bin/sh
# Forced-command wrapper: pins tmux to this host's own server socket dir,
# then runs the requested command unchanged (or a login shell for
# interactive sessions).
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
export TMUX_TMPDIR=$TMUX_DIR
exec /bin/sh -c "\${SSH_ORIGINAL_COMMAND:-exec \\\$SHELL -l}"
EOF
chmod +x "$DIR/wrap.sh"

printf 'command="%s/wrap.sh" %s\n' "$DIR" "$(cat "$DIR/clientkey.pub")" \
  > "$DIR/authorized_keys"
chmod 600 "$DIR/authorized_keys"

cat > "$DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/hostkey
PidFile $DIR/sshd.pid
MaxSessions 1
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile $DIR/authorized_keys
StrictModes no
LogLevel VERBOSE
EOF

# Restart cleanly if a previous instance is up.
if [ -L "$DIR/sshd.pid" ]; then
  echo "refusing symlinked sshd pid file" >&2
  exit 1
fi
if [ -f "$DIR/sshd.pid" ]; then
  old_pid=$(cat "$DIR/sshd.pid")
  case "$old_pid" in
    ''|*[!0-9]*) echo "invalid sshd pid file" >&2; exit 1 ;;
  esac
  if kill -0 "$old_pid" 2>/dev/null; then
    old_command=$(ps -p "$old_pid" -o command= 2>/dev/null || true)
    case "$old_command" in
      *"/usr/sbin/sshd -f $DIR/sshd_config"*) kill "$old_pid" ;;
      *) echo "refusing to kill unrelated process $old_pid" >&2; exit 1 ;;
    esac
    for _ in $(seq 1 50); do
      kill -0 "$old_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "timed out waiting for sshd $old_pid to exit" >&2
      exit 1
    fi
  fi
fi
/usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"

# Prove a login lands in the pinned tmux dir before calling it ready.
probe=$(ssh -p "$PORT" -i "$DIR/clientkey" -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$DIR/known_hosts" \
  "$USER@127.0.0.1" 'echo "$TMUX_TMPDIR"; tmux -V')
printf 'probe: %s\n' "$probe" | tr '\n' ' '; echo
case "$probe" in
  "$TMUX_DIR"*) ;;
  *) echo "FAIL: login did not land in $TMUX_DIR (is another sshd on port $PORT?)" >&2
     exit 1 ;;
esac

echo "ready. If ~/.ssh/config lacks it, add:"
cat <<EOF

Host $NAME
    HostName 127.0.0.1
    Port $PORT
    User $USER
    IdentityFile $DIR/clientkey
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
