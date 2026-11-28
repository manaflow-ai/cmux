#!/usr/bin/env bash
# Times `cmux link seed push` of one checkout into fresh folders on a local headless daemon,
# with the warm-mirror borrow on (CMUX_SEED_MIRRORS=ROOT) and off (the carry), N runs each,
# then a duress round of K pushes at once with the borrow on.
#
# usage: seed-push-bench.sh CMUX_TUI_BINARY SOURCE_CHECKOUT MIRRORS_ROOT WORK_DIR [N] [K]
# WORK_DIR must not exist; the script makes it and leaves its logs there.
set -euo pipefail
bin=$1 src=$2 mirrors=$3 work=$4 n=${5:-3} k=${6:-4}
mkdir "$work"

now() { date +%s.%N; }
secs() { python3 -I -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.2f}")' "$1" "$2"; }

start_daemon() { # name mirrors-or-empty
	local dir=$work/$1
	mkdir "$dir"
	if [ -n "$2" ]; then
		CMUX_SEED_MIRRORS=$2 "$bin" --headless --socket "$dir/s.sock" --state "$dir/state" >"$dir/daemon.log" 2>&1 &
	else
		env -u CMUX_SEED_MIRRORS "$bin" --headless --socket "$dir/s.sock" --state "$dir/state" >"$dir/daemon.log" 2>&1 &
	fi
	echo $! >"$dir/daemon.pid"
	for _ in $(seq 1 80); do [ -S "$dir/s.sock" ] && return 0; sleep 0.25; done
	echo "daemon $1 did not start" >&2
	cat "$dir/daemon.log" >&2
	return 1
}

push() { # daemon-name run-name -> prints "SECONDS RESULT_JSON"
	local dir=$work/$1 t0 t1 out
	t0=$(now)
	out=$("$bin" link seed push --socket "$dir/s.sock" "$src" "$dir/dst-$2" 2>&1 | tail -n 1) || true
	t1=$(now)
	echo "$(secs "$t0" "$t1") $out"
}

stop_daemons() { for p in "$work"/*/daemon.pid; do kill "$(cat "$p")" 2>/dev/null || true; done; }
trap stop_daemons EXIT

start_daemon borrow "$mirrors"
start_daemon carry ""
for i in $(seq 1 "$n"); do
	echo "borrow $i $(push borrow "$i")"
	echo "carry $i $(push carry "$i")"
done
t0=$(now)
for i in $(seq 1 "$k"); do push borrow "duress-$i" >"$work/borrow/duress-$i.out" & done
wait
echo "duress $k at once: $(secs "$t0" "$(now)") s wall"
cat "$work"/borrow/duress-*.out
