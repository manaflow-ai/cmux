#!/bin/bash
# runagent.sh VM NAME ARMS PREREG : the agent tier (codex gpt-6.1-sol via the host relay), detached; log in NAME.log
vm=$1 name=$2 arms=$3 prereg=$4
cd ~/truth-evals
nohup ./gs.sh $vm "mkdir -p ~/truth-out; cd ~/cu && ./gr.sh -t 40000 ./cuenv2.sh python3 -m cueval run --agent codex --model gpt-6.1-sol --trials 3 --split all --arms $arms --prereg /Users/admin/cu/evals/computer-use/macos/prereg/$prereg --out /Users/admin/truth-out/$name > /Users/admin/truth-out/$name.log 2>&1; echo rc=\$?" > $name.log 2>&1 &
echo started $name
