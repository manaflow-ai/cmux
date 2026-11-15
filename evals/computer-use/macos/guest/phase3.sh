#!/bin/bash
# phase3.sh : verify the harness fixes in the guest: the tool tier on the native fixture for both arms, then
# `cueval report` (crashed before), and re-score the agent tiers' transcript checks
cd ~/truth-evals
bash prep.sh truth-1 > phase3-prep.log 2>&1
./gs.sh truth-1 "cd ~/cu && ./gr.sh -t 600 ./cuenv2.sh cmux settings set computerUse.deniedApps '[]'; rm -rf ~/truth-out/tools; for arm in cmux-cu cua-driver-0.38.0; do ./gr.sh -t 1200 ./cuenv2.sh python3 -m cueval tools --arm \$arm --out /Users/admin/truth-out/tools/\$arm; done > ~/truth-out/tools.log 2>&1; ./gr.sh -t 300 ./cuenv2.sh python3 -m cueval report --out /Users/admin/truth-out/agent-a >> ~/truth-out/tools.log 2>&1; for d in agent-a agent-b; do ./gr.sh -t 300 ./cuenv2.sh python3 -m cueval recheck --out /Users/admin/truth-out/\$d; done >> ~/truth-out/tools.log 2>&1; echo rc=\$?" > phase3.log 2>&1
echo PHASE3-DONE > phase3.done
