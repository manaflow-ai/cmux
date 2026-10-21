#!/bin/zsh
# reset.sh {rex|cmux} [extra server args...]: stop both servers, then start one fresh.
# The server inherits this shell's limits, so callers set ulimit first.
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
REX="/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
CMUX=~/rex-bench/cmux-tui
kind=$1; shift
"$REX" --autostart=false server stop >/dev/null 2>&1
$CMUX daemon stop --session bench --force --end-terminals >/dev/null 2>&1
~/mux2/bin/mux2 stop >/dev/null 2>&1; pkill -f 'mux2/bin/mux2d' 2>/dev/null
pkill -f 'rex server run' 2>/dev/null; pkill -f 'cmux-tui daemon start' 2>/dev/null
pkill -x sleep 2>/dev/null
for _ in {1..50}; do pgrep -f 'rex server run|cmux-tui daemon start' >/dev/null || break; sleep 0.1; done
pkill -9 -f 'rex server run|cmux-tui daemon start' 2>/dev/null
rm -rf ~/rex-bench/state; mkdir -p ~/rex-bench/state ~/rex-bench/logs
case $kind in
  rex)  nohup "$REX" server run --state-dir ~/rex-bench/state "$@" >~/rex-bench/logs/rex.log 2>&1 </dev/null & ;;
  cmux) nohup $CMUX daemon start --session bench --state ~/rex-bench/state "$@" >~/rex-bench/logs/cmux.log 2>&1 </dev/null & ;;
  mux2) ~/mux2/bin/mux2 stats >/dev/null ;;
  none) exit 0 ;;
esac
for _ in {1..100}; do
  [[ $kind == mux2 ]] && break
  if [[ $kind == rex ]]; then "$REX" --autostart=false server status >/dev/null 2>&1 && break
  else $CMUX daemon status --session bench >/dev/null 2>&1 && break; fi
  sleep 0.1
done
echo "$kind up: pid $(pgrep -f 'rex server run|cmux-tui daemon start|mux2/bin/mux2d' | head -1) nofile=$(ulimit -n)"
