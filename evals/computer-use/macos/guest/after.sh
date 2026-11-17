#!/bin/bash
# after.sh RUN_DIR : once the tool-tier run is all done, the agent tier (cueval, Codex gpt-6.1-sol, three arms,
# 10 tasks x 3 trials) and the look-cost measurement for each arm, in the guest GUI session.
set -u
run=$1; cd ~/cu
until grep -q all-done "$run/progress.log" 2>/dev/null; do /bin/sleep 30; done
echo "$(date +%T) start agent" >> "$run/progress.log"
bash ~/cu/tidy.sh >/dev/null
./gr.sh -t 40000 ./cuenv3.sh python3 -m cueval run --arms cmux-cu,aside-1.26,codex-cu --agent codex --model gpt-6.1-sol \
  --trials 3 --tasks background-person-typing,denied-fixture-settings,form-checkbox,form-counter-exact,form-name-save,form-read-code,form-scroll-select,text-editor-append,two-windows-target,web-order-form \
  --out "$run/agent" > "$run/agent.log" 2>&1
echo "$(date +%T) done agent rc=$?" >> "$run/progress.log"
for arm in cmux-cu aside codex-cu; do
  bash ~/cu/tidy.sh >/dev/null
  ./gr.sh -t 1800 ./cuenv3.sh python3 /Users/admin/cu/evals/computer-use/macos/lookmeasure.py --arm $arm --out "$run/looks-$arm" > "$run/looks-$arm.log" 2>&1
done
echo "$(date +%T) after-done" >> "$run/progress.log"
