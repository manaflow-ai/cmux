#!/bin/bash
# golden.sh BASE GOLDEN ASSETS_DIR
#
# Builds the benchmark's golden VM from a Cirrus Labs base image already pulled
# as BASE: clone, SIP off (packer, Recovery), boot, copy assets, run
# guest/provision.sh, shut down. Every attempt then clones GOLDEN.
#
# ASSETS_DIR holds: codex-standalone/, codex-plugins/, "Codex Computer Use.app",
# codex-config.toml, optional codex-auth.json, and optionally cmux.app with
# cmux-app-name and cmux-bundle-ids.
set -euo pipefail
base=$1 golden=$2 assets=$3
here=$(cd "$(dirname "$0")/.." && pwd)
TART=${TART:-$HOME/cu-bench/bin/tart}
PACKER=${PACKER:-$HOME/cu-bench/bin/packer}
export PATH=$(dirname "$TART"):/opt/homebrew/bin:$PATH
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o PubkeyAuthentication=no -o PreferredAuthentications=password)

stage=${golden}-build
"$TART" delete "$stage" 2>/dev/null || true
"$TART" clone "$base" "$stage"
"$TART" set "$stage" --cpu 4 --memory 8192 --display 1440x900

if [[ ${SKIP_SIP:-0} != 1 ]]; then
  (cd "$here/tart" && "$PACKER" init disable-sip.pkr.hcl >/dev/null && "$PACKER" build -var "vm_name=$stage" disable-sip.pkr.hcl)
fi

"$TART" run --no-graphics "$stage" > "/tmp/$stage.log" 2>&1 &
run_pid=$!
ip=$("$TART" ip --wait 300 "$stage")
until sshpass -p admin ssh "${ssh_opts[@]}" "admin@$ip" 'pgrep -x Finder >/dev/null'; do /bin/sleep 3; done
sshpass -p admin ssh "${ssh_opts[@]}" "admin@$ip" 'csrutil status; rm -rf ~/cub-assets'
sshpass -p admin scp -q -r "${ssh_opts[@]}" "$assets" "admin@$ip:cub-assets"
sshpass -p admin scp -q "${ssh_opts[@]}" "$here/guest/provision.sh" "admin@$ip:provision.sh"
sshpass -p admin ssh "${ssh_opts[@]}" "admin@$ip" 'bash ~/provision.sh'
sshpass -p admin ssh "${ssh_opts[@]}" "admin@$ip" 'echo admin | sudo -S -p "" shutdown -h now' || true
wait "$run_pid" || true
"$TART" delete "$golden" 2>/dev/null || true
"$TART" rename "$stage" "$golden"
echo "golden VM $golden ready"
