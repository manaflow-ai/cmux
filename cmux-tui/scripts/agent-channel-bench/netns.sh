#!/usr/bin/env bash
# Two network namespaces (acb-a = "Mac end", acb-b = "Linux peer") joined by a veth pair with
# netem delay of RTT/2 on each direction, plus a real sshd in acb-b (port 22) for the ssh carrier.
# Usage: netns.sh up RTT_MS | down | exec a|b CMD...   (needs sudo; touches only acb-* netns)
set -euo pipefail
D=${ACB_DIR:-/tmp/acb}
case "${1:-}" in
up)
  rtt=${2:-50}; half=$(awk "BEGIN{print $rtt/2}")
  mkdir -p "$D"
  sudo ip netns add acb-a; sudo ip netns add acb-b
  sudo ip link add acb-va type veth peer name acb-vb
  sudo ip link set acb-va netns acb-a; sudo ip link set acb-vb netns acb-b
  for s in a b; do
    i=$([ $s = a ] && echo 1 || echo 2)
    sudo ip netns exec acb-$s ip addr add 10.77.0.$i/24 dev acb-v$s
    sudo ip netns exec acb-$s ip link set acb-v$s up
    sudo ip netns exec acb-$s ip link set lo up
    sudo ip netns exec acb-$s tc qdisc add dev acb-v$s root netem delay ${half}ms limit 10000
  done
  # sshd for the ssh carrier, key login only, in acb-b.
  [ -f "$D/host_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/host_key"
  [ -f "$D/id" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/id"
  cp "$D/id.pub" "$D/authorized_keys"; chmod 600 "$D/authorized_keys"
  cat > "$D/sshd_config" <<CFG
Port 22
ListenAddress 10.77.0.2
HostKey $D/host_key
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
UsePAM no
StrictModes no
PidFile $D/sshd.pid
AllowTcpForwarding yes
ForceCommand HOME=$D/hb exec /bin/sh -c "\$SSH_ORIGINAL_COMMAND"
CFG
  sudo ip netns exec acb-b /usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
  # ssh client config for acb-a (isolated HOME/known_hosts; no ControlMaster).
  cat > "$D/ssh_config" <<CFG
Host 10.77.0.2 box
  HostName 10.77.0.2
  User $(id -un)
  IdentityFile $D/id
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ControlMaster no
CFG
  echo "up: rtt=${rtt}ms"; sudo ip netns exec acb-a ping -c3 -i0.2 10.77.0.2 | tail -2 ;;
down)
  [ -f "$D/sshd.pid" ] && sudo kill "$(cat "$D/sshd.pid")" 2>/dev/null || true
  sudo ip netns del acb-a 2>/dev/null || true; sudo ip netns del acb-b 2>/dev/null || true ;;
exec)
  ns=acb-$2; shift 2
  exec sudo ip netns exec "$ns" sudo -u "$(id -un)" env "$@" ;;
*) echo "usage: $0 up RTT|down|exec a|b CMD" >&2; exit 2 ;;
esac
