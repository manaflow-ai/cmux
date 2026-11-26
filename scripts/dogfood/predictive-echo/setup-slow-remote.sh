#!/bin/bash
# Starts a user-level sshd on 127.0.0.1:2222 and adds `Host pe-slow` to
# ~/.ssh/config, reached through delay_proxy.py. Needs no sudo.
# Change the link with: echo '{"one_way_ms":75,"jitter_ms":20}' > ~/.cmux-dogfood/predictive-echo/link.json
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
d=${PE_DOGFOOD_DIR:-$HOME/.cmux-dogfood/predictive-echo}
mkdir -p "$d/sshd"
[ -f "$d/sshd/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$d/sshd/host_ed25519"
[ -f "$d/sshd/client_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$d/sshd/client_ed25519"
cp "$d/sshd/client_ed25519.pub" "$d/sshd/authorized_keys"
chmod 600 "$d/sshd/authorized_keys"
cat > "$d/sshd/sshd_config" <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $d/sshd/host_ed25519
AuthorizedKeysFile $d/sshd/authorized_keys
PidFile $d/sshd/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
Subsystem sftp /usr/libexec/sftp-server
CFG
if ! nc -z 127.0.0.1 2222 2>/dev/null; then
  /usr/sbin/sshd -f "$d/sshd/sshd_config" -E "$d/sshd/sshd.log"
fi
[ -f "$d/link.json" ] || echo '{"one_way_ms": 75, "jitter_ms": 0}' > "$d/link.json"
if ! grep -q '^Host pe-slow$' ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<CFG

# predictive echo dogfood: a local sshd behind a delaying relay
Host pe-slow
  HostName 127.0.0.1
  Port 2222
  User $USER
  IdentityFile $d/sshd/client_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile $d/sshd/known_hosts
  ProxyCommand /usr/bin/python3 $here/delay_proxy.py 127.0.0.1 2222 $d/link.json
CFG
fi
echo ready
