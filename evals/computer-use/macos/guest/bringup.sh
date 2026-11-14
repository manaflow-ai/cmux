#!/bin/bash
# bringup.sh : on the mini, after the golden copy: sparsify, clone truth-1, boot, stage fixture+harness, start engine
set -e
cd ~/truth-evals
/usr/bin/python3 punch.py ~/.tart/vms/truth-golden/disk.img
bin/tart clone truth-golden truth-1
(nohup bin/tart run --no-graphics truth-1 > truth-1.log 2>&1 &)
for i in $(seq 1 60); do ip=$(bin/tart ip truth-1 2>/dev/null) && break; sleep 3; done
echo "ip=$ip"
for i in $(seq 1 40); do ./gs.sh truth-1 true 2>/dev/null && break; sleep 3; done
bash stage.sh truth-1
bash prep.sh truth-1
./gcp.sh truth-1 boot.sh /Users/admin/cu/boot.sh
./gs.sh truth-1 "cd ~/cu && swiftc -O -o probe truth/probe.swift && bash ~/cu/boot.sh 2>&1 | tail -6"
tar cf aside-dl.tar aside-dl && ./gcp.sh truth-1 aside-dl.tar /tmp/aside-dl.tar && ./gs.sh truth-1 "cd ~ && tar xf /tmp/aside-dl.tar"
./gs.sh truth-1 "cd ~/cu && ./gr.sh -t 60 ./cuenv2.sh cmux settings set computerUse.deniedApps '[]'"
(nohup /usr/bin/python3 relay.py 192.168.64.1 31415 100.89.225.106 31415 > relay.log 2>&1 &)
df -g / | tail -1
echo BRINGUP-DONE
