#!/bin/zsh
# multi.sh {mux2|rex} N FILE: N terminals cat FILE at once; aggregate MB/s.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd ~/rex-bench
k=$1 n=$2 f=$3
R="/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"; M=~/mux2/bin/mux2
if [[ $k == rex ]]; then ./reset.sh rex --max-sessions 0 --max-blocks 0 >/dev/null; else ./reset.sh mux2 >/dev/null; fi
ids=()
for i in $(seq $n); do
  if [[ $k == rex ]]; then
    b=$("$R" --autostart=false new m$i --shell=none --keep-open --json -- /bin/sh -c "read go; exec /bin/cat '$f'" | grep -o 'block:[0-9a-f-]*' | head -1); ids+=("m$i $b")
  else ids+=($($M new --size 200x50 -- /bin/sh -c "read go; exec /bin/cat '$f'")); fi
done
t0=$(perl -MTime::HiRes=time -e 'print time')
for id in "${ids[@]}"; do
  if [[ $k == rex ]]; then set -- ${=id}; "$R" --autostart=false send -s $1 -b $2 $'\n' >/dev/null; else $M write $id $'\n'; fi
done
for id in "${ids[@]}"; do
  if [[ $k == rex ]]; then set -- ${=id}; "$R" --autostart=false wait -s $1 $2 >/dev/null; else $M wait $id >/dev/null; fi
done
t1=$(perl -MTime::HiRes=time -e 'print time')
cpu=$(ps -o time= -p $(pgrep -f 'rex server run|mux2/bin/mux2d' | head -1))
perl -e "printf qq({\"multi\":\"$k\",\"n\":$n,\"seconds\":%.2f,\"aggregate_mb_s\":%.0f,\"server_cpu\":\"$cpu\"}\n), $t1-$t0, $n*(-s q($f))/($t1-$t0)/1e6"
./reset.sh none >/dev/null
