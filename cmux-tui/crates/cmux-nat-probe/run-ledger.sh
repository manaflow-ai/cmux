#!/usr/bin/env bash
# One host's side of the NAT-traversal ledger: build the probe, run N pairs against a rendezvous (which answers with
# its own side b and keeps the ledger), then the same pair over Tailscale as a note row.
# usage: run-ledger.sh RENDEZVOUS_HOST:PORT [RUNS] [CLASS]
# CLASS defaults from the default route's interface: Wi-Fi is home-wifi, anything else office-datacenter. A class with
# no real network (cellular, hotel-cgnat) is only ever passed by a person on that network.
set -uo pipefail
rv=${1:?rendezvous HOST:PORT}
runs=${2:-10}
cd "$(dirname "$0")/../.." || exit 2
export PATH="$HOME/.cargo/bin:$PATH"
cargo build -q -p cmux-nat-probe || exit 2
probe=target/debug/cmux-nat-probe
iface=$( (route -n get default 2>/dev/null | awk '/interface:/{print $2}') || true)
[[ -n "$iface" ]] || iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1); exit}')
wifi=no
if [[ "$(uname)" == Darwin ]] && networksetup -listallhardwareports 2>/dev/null | grep -A1 'Wi-Fi' | grep -q "Device: $iface"; then
  wifi=yes
fi
class=${3:-$([[ $wifi == yes ]] && echo home-wifi || echo office-datacenter)}
label="$class/$(hostname -s)-$(uname -s | tr 'A-Z' 'a-z')-$iface"
echo "ledger: $label against $rv, $runs runs"
for ((i = 1; i <= runs; i++)); do
  "$probe" pair --role a --token "$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')" --rendezvous "$rv" --label "$label" \
    --duration-ms 12000 --pings 40 | grep '^RESULT' | cut -c1-400
done
ts=tailscale
[[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]] && ! command -v tailscale >/dev/null && ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
"$probe" tailscale --rendezvous "$rv" --label "$label" --count 20 --tailscale-bin "$ts"
