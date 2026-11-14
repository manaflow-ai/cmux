#!/bin/bash
# runarm.sh VM ARM OUTNAME [extra truthmatrix args] : on the mini host, run the full truth matrix for one arm
# in the guest's GUI session (3 reps, bg+fg), detached from the ssh session; log in ~/truth-evals/OUTNAME.log
vm=$1 arm=$2 name=$3; shift 3
cd ~/truth-evals
nohup ./gs.sh $vm "mkdir -p ~/truth-out; cd ~/cu && ./gr.sh -t 30000 ./cuenv2.sh python3 /Users/admin/cu/truth/truthmatrix.py --arm $arm --reps 3 --out /Users/admin/truth-out/$name $* > /Users/admin/truth-out/$name.log 2>&1; echo rc=\$?" > $name.log 2>&1 &
echo started $name
