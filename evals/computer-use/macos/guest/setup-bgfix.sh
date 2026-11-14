#!/bin/bash
# setup-bgfix.sh VM : swap the guest app's cmux Remote helper for the bg-fix branch's signed build (remote34)
set -e
vm=${1:-truth-1}
cd ~/truth-evals
bash prep.sh $vm
./gcp.sh $vm remote34.zip /Users/admin/remote34.zip
./gs.sh $vm 'bash ~/cu/swapremote2.sh ~/remote34.zip 2>&1 | tail -5; bash ~/cu/boot.sh 2>&1 | grep -E "worker|dylib|deny|denied" | cut -c1-200'
./gs.sh $vm "cd ~/cu && ./gr.sh -t 60 ./cuenv2.sh cmux settings set computerUse.deniedApps '[]'"
