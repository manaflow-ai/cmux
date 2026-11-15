#!/bin/bash
# usage: hover-shots.sh NAME PID WIN OUTDIR  -- points are window-relative
NAME=$1; PID=$2; WIN=$3; OUT=$4; cd ~/density-helium
python3 cua.py bring_to_front "{\"pid\":$PID}" >/dev/null; sleep 1
B=$(python3 cua.py list_windows "{\"pid\":$PID}" | python3 -c "import json,sys; w=[x for x in json.load(sys.stdin)['windows'] if x['window_id']==$WIN][0]['bounds']; print(int(w['x']), int(w['y']))")
set -- $B; WX=$1; WY=$2
shot() { python3 cua.py get_window_state "{\"pid\":$PID,\"window_id\":$WIN,\"max_elements\":1,\"screenshot_out_file\":\"$OUT/$NAME-$1.png\"}" >/dev/null; }
./mouse $((WX+700)) $((WY+400)); sleep 1.2; shot rest
for spec in "hover-active-x:${HX1}:17" "hover-inactive-tab:${HT2}:17" "hover-inactive-x:${HX2}:17" "hover-newtab:${HN}:17" "hover-back:${HB}:${HY}" "hover-ext:${HE}:${HY}"; do
  n=${spec%%:*}; r=${spec#*:}; x=${r%%:*}; y=${r#*:}
  [ -z "$x" ] && continue
  ./mouse $((WX+x-6)) $((WY+y+2)); sleep 0.3; ./mouse $((WX+x)) $((WY+y)); sleep 1.0; shot $n
done
./mouse $((WX+700)) $((WY+400))
