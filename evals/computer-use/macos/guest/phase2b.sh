#!/bin/bash
# phase2b.sh : the covered background scene (bgc): Person window above the target, checked per cell.
# Lab: 3 reps per arm; real apps: 1 rep per arm. Rewrite-helper arms first, then the bg-fix helper.
cd ~/truth-evals
cp harness-p3.tgz harness.tgz
bash prep.sh truth-1 > phase2b-prep.log 2>&1
run() { # arm name apps reps
  ./gs.sh truth-1 "mkdir -p ~/truth-out; cd ~/cu && ./cuenv2.sh true; ./gr.sh -t 20000 ./cuenv2.sh python3 /Users/admin/cu/truth/truthmatrix.py --arm $1 --apps $3 --scenes bgc --reps $4 --out /Users/admin/truth-out/$2 > /Users/admin/truth-out/$2.log 2>&1; echo rc=\$?" >> phase2b.log 2>&1
}
./gs.sh truth-1 "cd ~/cu && ./gr.sh -t 60 ./cuenv2.sh cmux settings set computerUse.deniedApps '[]'" >> phase2b.log 2>&1
run cmux-cu  a-bgc   lab 3
run cua-driver-0.38.0 c-bgc lab 3
run aside    d-bgc   lab 3
run cmux-cu  a-bgc-real textedit,calculator,safari,finder,notes,settings 1
run cua-driver-0.38.0 c-bgc-real textedit,calculator,safari,finder,notes,settings 1
run aside    d-bgc-real textedit,calculator,safari,finder,notes,settings 1
bash setup-bgfix.sh truth-1 >> phase2b.log 2>&1
run cmux-cu  b-bgc   lab 3
run cmux-cu  b-bgc-real textedit,calculator,safari,finder,notes,settings 1
echo PHASE2B-DONE > phase2b.done
