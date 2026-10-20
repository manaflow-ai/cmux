#!/bin/zsh
# analyze_keyboard.sh <evidence-dir> <label>
# 1. track_video.py finds every keyboard show/hide in <label>.mp4.
# 2. Each transition is re-extracted frame by frame at full resolution
#    (frames named by presentation time) and measured by keyboard_track.py.
set -e
E=$1; L=$2; S=${0:a:h}
cd $E
python3 $S/track_video.py $L.mp4 $L.track.csv > $L.transitions.txt
grep -E "^(show|hide)" $L.transitions.txt | sed -E 's/^(show|hide) t= *([0-9.]+)-.*/\1 \2/' | while read kind start; do
  # TUI (htop) transitions: between the timeline's "run htop" and "quit htop".
  tui=""
  if [[ -f $L.timeline.txt && -f $L.recstart.txt ]]; then
    R=$(cat $L.recstart.txt)
    a=$(grep -m1 "run htop" $L.timeline.txt | cut -d' ' -f1); b=$(grep -m1 "quit htop" $L.timeline.txt | cut -d' ' -f1)
    [[ -n $a && -n $b ]] && [[ $(python3 -c "print(1 if $a-$R+2 < $start < $b-$R+2 else 0)") == 1 ]] && tui="--tui"
  fi
  O=frames/$L-$kind-$start
  rm -rf $O; $S/frames.sh $L.mp4 $(python3 -c "print(max(0,$start-0.08))") 0.75 $O 1206 >/dev/null
  python3 $S/keyboard_track.py $O $tui > $O.txt
  echo "$kind $start ${tui:+TUI }$(head -1 $O.txt) | $(grep -E 'moving|tui_row_vs' $O.txt | tr '\n' ' ')"
done
