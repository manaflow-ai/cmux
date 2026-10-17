#!/bin/zsh
# Upgrade-survival gate: terminals keep their exact state, live programs keep
# running, and exit codes still arrive after an in-place upgrade.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
M=~/mux2/bin/mux2; C=~/mux2/corpus; T=$(mktemp -d)
$M stop 2>/dev/null; pkill -f mux2/bin/mux2d
a=$($M new --size 120x40 -- /bin/cat $C/cursor.txt); $M wait $a >/dev/null
b=$($M new --size 100x30 -- /bin/cat)
c=$($M new --size 80x24 -- /bin/sleep 100000)
d=$($M new --size 132x43 -- /bin/sh -c "cat $C/unicode.txt; echo STREAM-END; exec cat")
until $M screen $d | grep -q STREAM-END; do :; done; $M stats | grep bytes_in
for t in $a $b $c $d; do $M replay $t > $T/before-$t.vt; $M screen $t > $T/before-$t.txt; done
pid_before=$(pgrep -f mux2/bin/mux2d)
$M upgrade || { echo '{"upgrade":"FAILED"}'; exit 1; }
pid_after=$(pgrep -f mux2/bin/mux2d)
ok=true
for t in $a $b $c $d; do
  $M replay $t > $T/after-$t.vt; $M screen $t > $T/after-$t.txt
  cmp -s $T/before-$t.vt $T/after-$t.vt && rv=exact || { rv=DIFF; ok=false; }
  cmp -s $T/before-$t.txt $T/after-$t.txt && sc=same || { sc=DIFF; ok=false; }
  echo "{\"terminal\":$t,\"replay\":\"$rv\",\"screen\":\"$sc\",\"replay_bytes\":$(wc -c < $T/after-$t.vt)}"
done
$M write $b 'after-upgrade-marker'$'\n'
until $M screen $b | grep -q after-upgrade-marker; do :; done; echo '{"live_input":"ok"}'
kill -TERM $(pgrep -f 'sleep 100000'); code=$($M wait $c); [[ $code == 143 ]] || ok=false
echo "{\"pid_before\":$pid_before,\"pid_after\":$pid_after,\"killed_exit\":$code,\"ok\":$ok}"
$M ls; $M stop; rm -rf $T
