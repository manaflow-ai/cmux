#!/bin/bash
# setup-aside.sh VM : install the pinned Aside daemon + CLI in the guest (sha256-checked), grant TCC, start the
# daemon in the GUI session, enable its computer use (no sign-in; the path AgentEnv's aside driver uses)
set -e
vm=${1:-truth-2}
cd ~/truth-evals
bash prep.sh $vm
./gs.sh $vm 'bash ~/cu/install-aside.sh >/dev/null && bash ~/cu/grant-aside.sh | tail -2'
./gs.sh $vm 'cd ~/cu && ./gr.sh -b /Users/admin/cu/aside-daemon.sh'
./gs.sh $vm 'for i in $(seq 1 60); do curl -s 127.0.0.1:21420/health | grep -q true && break; sleep 2; done; curl -s 127.0.0.1:21420/health; echo'
./gs.sh $vm '~/cu/aside-env.sh ~/aside/bin/aside settings computer-use enable; ~/cu/aside-env.sh ~/aside/bin/aside settings analytics disable; echo aside-ready'
