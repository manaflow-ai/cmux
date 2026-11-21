#!/bin/zsh
# hometabs.sh APP SOCK OUT : Home pane with a second tab (its tab strip shows, sharing the row with Home's tools), user look, light/dark.
cd ~/density-helium
A="$1"; S="$2"; O="$3"; C="$A/Contents/Resources/bin/cmux"
nohup "$A/Contents/MacOS/cmux DEV" >run.log 2>&1 & P=$!
for i in $(seq 1 40); do [ -S $S ] && break; sleep 1; done; sleep 15
HP=$("$C" --app-socket $S --json pane list 2>/dev/null | python3 -c '
import json,sys,subprocess
for p in json.load(sys.stdin):
    t=subprocess.run([sys.argv[1],"--app-socket",sys.argv[2],"--json","tab","list","--pane",p["id"]],capture_output=True,text=True).stdout
    if "home-dock" in t: print(p["id"]); break' "$C" $S)
echo homepane=$HP
N=$("$C" --app-socket $S --json tab list --pane $HP | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$N" -lt 2 ] && CMUX_SOCKET_PATH=$S "$C" --app-socket $S tab create terminal --pane $HP 2>&1 | tail -1
sleep 2
HT=$("$C" --app-socket $S --json tab list --pane $HP | python3 -c '
import json,sys
for t in json.load(sys.stdin):
    if "home-dock" in json.dumps(t): print(t["id"])')
"$C" --app-socket $S tab $HT focus 2>&1 | tail -1
sleep 3
W=$(python3 -c "
import sys; sys.path.insert(0,'.'); import rpc
ws=(rpc.rpc('debug.focus',{},'$S').get('result',{}).get('windows') or [])
print(ws[0]['id'] if ws else '')")
python3 dockshots.py $S $O $W 2>&1 | grep -E "dark|light|restored" | cut -c1-100
kill $P; sleep 3
