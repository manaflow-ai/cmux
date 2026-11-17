#!/bin/bash
# threeway.sh OUT ARMS PHASES : in the guest (over ssh), run the tool-tier matrices for each arm, one at a time,
# in the GUI session (gr.sh). PHASES: bg (background matrix: rep 1 under a screen recording, then reps 2-3),
# truth (truth matrix, 3 reps, bg+fg scenes). Same VM, same harness, same apps for every arm.
set -u
out=$1; arms=${2:-cmux-cu,aside,codex-cu}; phases=${3:-bg,truth}
mkdir -p "$out"; cd ~/cu
H=/Users/admin/cu/evals/computer-use/macos
entry_bg() { case $1 in aside*) echo $H/aside_arm.py;; codex*) echo $H/codex_arm.py;; *) echo $H/bgmatrix.py;; esac; }
entry_tr() { case $1 in codex*) echo $H/codex_truth.py;; *) echo $H/truthmatrix.py;; esac; }
for ph in ${phases//,/ }; do
  for arm in ${arms//,/ }; do
    bash ~/cu/tidy.sh >/dev/null
    d=$out/$ph-$arm; mkdir -p "$d"
    echo "$(date +%T) start $ph $arm" >> "$out/progress.log"
    if [[ $ph == bg ]]; then
      ./gr.sh -b screencapture -x -v -V 1500 "$d/rep1-$arm.mov" > "$d/rec.job"
      ./gr.sh -t 5000 ./cuenv3.sh python3 "$(entry_bg $arm)" --arm $arm --reps 1 --rep-start 1 --out "$d" > "$d/rep1.log" 2>&1
      pkill -INT -x screencapture; /bin/sleep 3
      ./gr.sh -t 9000 ./cuenv3.sh python3 "$(entry_bg $arm)" --arm $arm --reps 2 --rep-start 2 --out "$d" > "$d/rep23.log" 2>&1
    else
      ./gr.sh -t 30000 ./cuenv3.sh python3 "$(entry_tr $arm)" --arm $arm --reps 3 --out "$d" > "$d/truth.log" 2>&1
    fi
    echo "$(date +%T) done $ph $arm rc=$?" >> "$out/progress.log"
  done
done
echo all-done >> "$out/progress.log"
