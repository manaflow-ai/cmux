#!/bin/bash
# clips.sh OUT ARM:APP:ACTION... : record one bgmatrix cell per spec under a screen recording (rep 1 only), for the
# report's notable-cell clips. Same harness, same scene (the Person window in front, typing).
set -u
out=$1; shift; mkdir -p "$out"; cd ~/cu
H=/Users/admin/cu/evals/computer-use/macos
for spec in "$@"; do
  IFS=: read -r arm app action <<< "$spec"
  case $arm in aside*) e=$H/aside_arm.py;; codex*) e=$H/codex_arm.py;; *) e=$H/bgmatrix.py;; esac
  d=$out/$arm-$app-$action; rm -rf "$d"; mkdir -p "$d"
  bash ~/cu/tidy.sh >/dev/null
  ./gr.sh -b screencapture -x -v -V 240 "$d/clip.mov" > "$d/rec.job"
  ./gr.sh -t 600 ./cuenv3.sh python3 "$e" --arm $arm --apps $app --actions $action --reps 1 --out "$d" > "$d/run.log" 2>&1
  pkill -INT -x screencapture; /bin/sleep 3
  echo "$spec $(tail -1 $d/run.log | cut -c1-160)" >> "$out/clips.log"
done
echo clips-done >> "$out/clips.log"
