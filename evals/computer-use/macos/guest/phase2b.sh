#!/bin/bash
# phase2b.sh : the covered background scene (bgc), 1 rep: lab for every arm, real apps for the two cmux helpers
cd ~/truth-evals
cp harness-p3.tgz harness.tgz
bash prep.sh truth-1 > phase2b-prep.log 2>&1
run() { # arm name apps
  ./gs.sh truth-1 "mkdir -p ~/truth-out; cd ~/cu && ./gr.sh -t 20000 ./cuenv2.sh python3 /Users/admin/cu/truth/truthmatrix.py --arm $1 --apps $3 --scenes bgc --reps 1 --out /Users/admin/truth-out/$2 > /Users/admin/truth-out/$2.log 2>&1; echo rc=\$?" >> phase2b.log 2>&1
}
./gs.sh truth-1 "cd ~/cu && ./gr.sh -t 60 ./cuenv2.sh cmux settings set computerUse.deniedApps '[]'" >> phase2b.log 2>&1
run cua-driver-0.38.0 c-bgc lab
run aside    d-bgc   lab
run cmux-cu  a-bgc-real textedit,calculator,safari,finder,notes,settings
bash setup-bgfix.sh truth-1 >> phase2b.log 2>&1
run cmux-cu  b-bgc   lab
run cmux-cu  b-bgc-real textedit,calculator,safari,finder,notes,settings
echo PHASE2B-DONE > phase2b.done
