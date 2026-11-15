#!/bin/bash
# phase1.sh : on mini-5 after bring-up: bg-fix helper; arm (b) for the apps not finished on mini-cmux13s; then its agent tier
cd ~/truth-evals
bash setup-bgfix.sh truth-1 > phase1-setup.log 2>&1
./gs.sh truth-1 "mkdir -p ~/truth-out; cd ~/cu && ./gr.sh -t 20000 ./cuenv2.sh python3 /Users/admin/cu/truth/truthmatrix.py --arm cmux-cu --apps calculator,safari,finder,notes,settings --reps 3 --out /Users/admin/truth-out/b2-cmux-bgfix > /Users/admin/truth-out/b2-cmux-bgfix.log 2>&1; echo rc=\$?" > b2.log 2>&1
./gs.sh truth-1 "cd ~/cu && ./gr.sh -t 40000 ./cuenv2.sh python3 -m cueval run --agent codex --model gpt-6.1-sol --trials 3 --split all --arms cmux-cu --prereg /Users/admin/cu/evals/computer-use/macos/prereg/prereg-agent-b.json --out /Users/admin/truth-out/agent-b > /Users/admin/truth-out/agent-b.log 2>&1; echo rc=\$?" > agent-b.log 2>&1
echo PHASE1-DONE > phase1.done
