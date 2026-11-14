#!/bin/bash
# prep.sh VM : push the branch's harness (keeping the guest's .cache) and the guest scripts into the VM
set -e
vm=${1:-truth-1}
cd ~/truth-evals
./gcp.sh $vm harness.tgz /tmp/harness.tgz
./gcp.sh $vm guest.tgz /tmp/guest.tgz
./gs.sh $vm 'set -e; cd ~/cu; tar xzf /tmp/harness.tgz -C ~/cu/evals; tar xzf /tmp/guest.tgz -C /tmp; cp /tmp/guest/*.sh ~/cu/; mkdir -p ~/cu/truth; cp ~/cu/evals/computer-use/macos/*.py ~/cu/evals/computer-use/macos/page.html ~/cu/evals/computer-use/macos/probe.swift ~/cu/truth/; cp ~/cu/truth/page.html ~/cu/page.html; ls ~/cu/evals/computer-use/.cache/cua-driver-0.38.0/macos-arm64/cua-driver && echo prepped'
