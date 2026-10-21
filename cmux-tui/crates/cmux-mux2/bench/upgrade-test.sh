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
# A failed upgrade must change nothing.
if $M upgrade /nonexistent/mux2d 2>/dev/null; then echo '{"bad_upgrade":"ACCEPTED"}'; ok_bad=false; else ok_bad=true; fi
for t in $a $b $c $d; do $M replay $t | cmp -s - $T/before-$t.vt || ok_bad=false; done
[[ $(pgrep -f mux2/bin/mux2d) == $pid_before ]] || ok_bad=false
echo "{\"bad_upgrade_harmless\":$ok_bad}"
# A wait that spans the upgrade must still get the exit code.
$M wait $c > $T/wait-out &
waiter=$!
# A killed terminal whose child outlives the upgrade must still be reaped.
e=$($M new -- /bin/sh -c 'trap "" HUP; exec /bin/sleep 3')
until pgrep -f 'sleep 3$' >/dev/null; do :; done; orphan=$(pgrep -f 'sleep 3$')
$M kill $e
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
wait $waiter; spanning=$(cat $T/wait-out); [[ $spanning == 143 ]] || ok=false
while kill -0 $orphan 2>/dev/null && [[ $(ps -o stat= -p $orphan) != Z* ]]; do :; done
zombie=$(ps -o stat= -p $orphan 2>/dev/null | grep -c Z); [[ $zombie == 0 ]] || ok=false
$ok_bad || ok=false
echo "{\"wait_across_upgrade\":\"$spanning\",\"orphan_zombie\":$zombie}"
echo "{\"pid_before\":$pid_before,\"pid_after\":$pid_after,\"killed_exit\":$code,\"ok\":$ok}"
$M ls; $M stop; rm -rf $T
