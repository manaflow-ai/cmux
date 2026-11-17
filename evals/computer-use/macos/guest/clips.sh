#!/bin/bash
# clips.sh OUT SECONDS ARM:APP:ACTION... : record one bgmatrix cell per spec (rep 1) under a fixed-length screen
# recording (screencapture -V SECONDS, left to finish on its own), for the report's notable-cell clips.
set -u
out=$1; secs=$2; shift 2; mkdir -p "$out"; cd ~/cu
H=/Users/admin/cu/evals/computer-use/macos
for spec in "$@"; do
  IFS=: read -r arm app action <<< "$spec"
  case $arm in aside*) e=$H/aside_arm.py;; codex*) e=$H/codex_arm.py;; *) e=$H/bgmatrix.py;; esac
  d=$out/$arm-$app-$action; rm -rf "$d"; mkdir -p "$d"
  bash ~/cu/tidy.sh >/dev/null
  read -r _ _ rc < <(./gr.sh -b screencapture -x -v -V "$secs" "$d/clip.mov")
  ./gr.sh -t 600 ./cuenv3.sh python3 "$e" --arm $arm --apps $app --actions $action --reps 1 --out "$d" > "$d/run.log" 2>&1
  for i in $(seq 1 $((secs + 30))); do [ -f "$rc" ] && break; /bin/sleep 1; done
  echo "$spec $(ls -la $d/clip.mov 2>&1 | awk '{print $5}') $(tail -1 $d/run.log | cut -c1-160)" >> "$out/clips.log"
done
echo clips-done >> "$out/clips.log"
