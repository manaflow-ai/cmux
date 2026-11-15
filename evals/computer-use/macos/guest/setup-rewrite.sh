#!/bin/bash
# setup-rewrite.sh VM : put the rewrite helper back (remote29 = the golden's helper, dylib ad12c392...)
set -e
vm=${1:-truth-1}
cd ~/truth-evals
bash prep.sh $vm
./gcp.sh $vm remote29.zip /Users/admin/remote29.zip
./gs.sh $vm 'bash ~/cu/swapremote2.sh ~/remote29.zip 2>&1 | tail -3; bash ~/cu/boot.sh 2>&1 | grep -E "dylib" | cut -c1-90'
./gs.sh $vm "cd ~/cu && ./gr.sh -t 60 ./cuenv2.sh cmux settings set computerUse.deniedApps '[]'"
