#!/bin/zsh
# Throughput, query reply latency and round trips for rex, cmux and mux2.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd ~/rex-bench
R="/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"; C=~/rex-bench/cmux-tui; M=~/mux2/bin/mux2
up() { if [[ $1 == rex ]]; then ./reset.sh rex --max-sessions 0 --max-blocks 0; else ./reset.sh $1; fi >/dev/null; }
for k in mux2 rex cmux; do
  for f in $HOME/rex-bench/data-plain.txt $HOME/rex-bench/data-ansi.txt; do
    for a in "" --attach; do up $k; perl bench.pl tput $k $f $a | sed "s|}\$|,\"file\":\"${f:t}\"}|"; done
  done
done
q=$HOME/rex-bench/query-rtt.pl
up mux2; id=$($M new --size 120x40 -- /usr/bin/perl $q 1000); $M wait $id >/dev/null; $M screen $id | grep -E 'query_rtt|BAD' | sed 's/^/{"kind":"mux2",/;s/{"query/"query/'
up rex; "$R" --autostart=false new q --shell=none --keep-open -- /usr/bin/perl $q 1000 >/dev/null; "$R" --autostart=false wait -s q 1 >/dev/null 2>&1; "$R" --autostart=false capture -s q --trim | grep -E 'query_rtt|BAD' | sed 's/^/{"kind":"rex",/;s/{"query/"query/'
up cmux; t=$($C --session bench --json workspace create --name q -- /usr/bin/perl $q 1000 | jq -r .value.terminal_id); $C --session bench terminal $t process wait --timeout-ms 600000 >/dev/null; $C --session bench terminal $t screen read | grep -E 'query_rtt|BAD' | sed 's/^/{"kind":"cmux",/;s/{"query/"query/'
for k in mux2 rex cmux; do up $k; perl bench.pl rtt $k 200; done
up mux2; $M bench create 300; $M bench rtt 1000
./reset.sh none
