#!/usr/bin/env bash
# The SSH host of the Remote GUI proof (remote-gui-proof.yml): a second local macOS account reached over a
# key-only sshd on 127.0.0.1, on the throwaway CI Mac the proof runs on. Nothing listens beyond
# loopback and nothing outside the runner changes.
#
#   remote-gui-proof-host.sh up DIR      make the account (rhost), its stand-in `claude`, a key-only sshd on
#                                        127.0.0.1:$PORT and the runner user's ssh alias `e2ehost`; DIR keeps the
#                                        keys, the sshd config, its pid and log
#   remote-gui-proof-host.sh drop DIR    the network drop: pf drops every packet to or from $PORT on lo0,
#                                        established connections included (pf starts with no state for them)
#   remote-gui-proof-host.sh restore DIR the network back: the pf rules this script loaded are removed
#   remote-gui-proof-host.sh down DIR    stop the sshd this script started (its own pid file) and pf if loaded
#
# It refuses to run anywhere but a throwaway CI Mac: it adds a user and rewrites pf rules.
set -euo pipefail

USER_NAME=rhost
ALIAS=e2ehost
PORT="${REMOTE_GUI_PROOF_PORT:-2222}"
cmd="${1:-}"
dir="${2:-}"
[ -n "$cmd" ] && [ -n "$dir" ] || { echo "usage: $0 up|drop|restore|down DIR" >&2; exit 2; }
# remote-gui-proof.yml sets REMOTE_GUI_PROOF_THROWAWAY=1 on its job, whose runs-on is an ephemeral Mac.
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "$(uname)" != Darwin ] \
  || { [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ] && [ "${REMOTE_GUI_PROOF_THROWAWAY:-}" != 1 ]; }; then
  echo "remote-gui-proof-host.sh runs only on a throwaway CI Mac (it adds a user and pf rules)" >&2
  exit 2
fi
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
home="/Users/$USER_NAME"

stamp() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(stamp)] $*"; }

up() {
  if ! id "$USER_NAME" >/dev/null 2>&1; then
    pw="$(openssl rand -hex 24)"
    say "adding user $USER_NAME"
    sudo sysadminctl -addUser "$USER_NAME" -fullName "Remote GUI proof host" -password "$pw" -home "$home" -shell /bin/zsh 2>&1 | tail -n 3 || true
    unset pw
  fi
  id "$USER_NAME"
  sudo createhomedir -c -u "$USER_NAME" >/dev/null 2>&1 || true
  [ -d "$home" ] || sudo mkdir -p "$home"
  sudo chown "$USER_NAME:staff" "$home"
  sudo chmod 755 "$home"
  # macOS's sshd lets in only members of com.apple.access_ssh when that group exists (Remote Login's ACL).
  if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
    sudo dseditgroup -o edit -a "$USER_NAME" -t user com.apple.access_ssh || true
  fi

  # The runner user's key, authorized for rhost only.
  [ -f "$dir/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C remote-gui-proof -f "$dir/id_ed25519"
  sudo mkdir -p "$home/.ssh" "$home/.local/bin"
  sudo cp "$dir/id_ed25519.pub" "$home/.ssh/authorized_keys"
  # A stand-in Claude Code first on rhost's PATH (no Claude login on the runner): the same one the remote-ssh
  # scoreboard probe uses, answering every turn with PONG.
  sudo cp "$(dirname "$0")/remote-gui-proof-claude.py" "$home/.local/bin/claude"
  sudo chmod 755 "$home/.local/bin/claude"
  for f in .zshenv .profile .bashrc; do
    echo 'export PATH="$HOME/.local/bin:$PATH"' | sudo tee "$home/$f" >/dev/null
  done
  sudo chown -R "$USER_NAME:staff" "$home/.ssh" "$home/.local" "$home/.zshenv" "$home/.profile" "$home/.bashrc"
  sudo chmod 700 "$home/.ssh"
  sudo chmod 600 "$home/.ssh/authorized_keys"

  # A key-only sshd on loopback, with its own host key and config.
  [ -f "$dir/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$dir/ssh_host_ed25519_key"
  sudo chown root:wheel "$dir/ssh_host_ed25519_key"
  sudo chmod 600 "$dir/ssh_host_ed25519_key"
  cat > "$dir/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $dir/ssh_host_ed25519_key
PidFile $dir/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers $USER_NAME
StrictModes yes
ClientAliveInterval 5
ClientAliveCountMax 3
Subsystem sftp /usr/libexec/sftp-server
EOF
  sudo /usr/sbin/sshd -t -f "$dir/sshd_config"
  if [ -f "$dir/sshd.pid" ] && sudo kill -0 "$(cat "$dir/sshd.pid")" 2>/dev/null; then
    say "sshd already running: $(cat "$dir/sshd.pid")"
  else
    sudo /usr/sbin/sshd -f "$dir/sshd_config" -E "$dir/sshd.log"
    for _ in $(seq 1 50); do [ -s "$dir/sshd.pid" ] && break; sleep 0.1; done
    say "sshd pid $(cat "$dir/sshd.pid") on 127.0.0.1:$PORT"
  fi

  # The runner user's ssh alias, the host a person types into Add machine.
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  hostkey="$(cut -d' ' -f1-2 "$dir/ssh_host_ed25519_key.pub")"
  echo "[127.0.0.1]:$PORT $hostkey" >> "$HOME/.ssh/known_hosts"
  if ! grep -q "^Host $ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" <<EOF

Host $ALIAS
  HostName 127.0.0.1
  Port $PORT
  User $USER_NAME
  IdentityFile $dir/id_ed25519
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
EOF
  fi
  chmod 600 "$HOME/.ssh/config"
  # The same stand-in for the runner user, so a chat on this Mac (the move step's start) answers too.
  mkdir -p "$HOME/.local/bin"
  cp "$(dirname "$0")/remote-gui-proof-claude.py" "$HOME/.local/bin/claude"
  chmod 755 "$HOME/.local/bin/claude"
  for f in .zshenv .zprofile; do
    grep -q 'remote-gui-proof' "$HOME/$f" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH" # remote-gui-proof' >> "$HOME/$f"
  done
  # The check a person's terminal would make: the alias logs in and the stand-in is first on PATH.
  say "ssh check"
  ssh "$ALIAS" 'echo "whoami=$(whoami) claude=$(command -v claude) $(claude --version)"; sw_vers -productVersion; uname -m'
}

pf_rules() {
  cat <<EOF
block drop quick on lo0 proto tcp from any to any port $PORT
block drop quick on lo0 proto tcp from any port $PORT to any
EOF
}

drop() {
  pf_rules > "$dir/pf-drop.conf"
  # A ruleset of our own on a throwaway runner; restore loads /etc/pf.conf back.
  sudo pfctl -q -f "$dir/pf-drop.conf" 2>&1 | grep -v -i 'ALTQ' || true
  token="$(sudo pfctl -E 2>&1 | sed -n 's/^Token : //p')"
  echo "$token" > "$dir/pf.token"
  sudo pfctl -q -F states 2>/dev/null || true
  say "pf drops 127.0.0.1:$PORT (token ${token:-none})"
}

restore() {
  if [ -s "$dir/pf.token" ]; then
    sudo pfctl -q -X "$(cat "$dir/pf.token")" 2>/dev/null || true
    rm -f "$dir/pf.token"
  fi
  sudo pfctl -q -f /etc/pf.conf 2>&1 | grep -v -i 'ALTQ' || true
  say "pf rules removed"
}

down() {
  restore || true
  if [ -s "$dir/sshd.pid" ]; then
    sudo kill "$(cat "$dir/sshd.pid")" 2>/dev/null || true
    say "sshd stopped"
  fi
}

case "$cmd" in
  up) up ;;
  drop) drop ;;
  restore) restore ;;
  down) down ;;
  *) echo "usage: $0 up|drop|restore|down DIR" >&2; exit 2 ;;
esac
