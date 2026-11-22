#!/bin/bash
# Held-and-burst link profiles for a two-Mac screen-share run: dummynet on the host Mac's egress to the
# viewer's addresses only. Run as root on the host Mac (fleet-sudo HOST /bin/bash mac-holds.sh ...).
#   mac-holds.sh schedule PROFILE MAX_S          print the profile's hold schedule (JSON lines; no root)
#   mac-holds.sh start PROFILE MAX_S PEER_IP...  apply PROFILE; a detached watchdog ends it all after MAX_S
#   mac-holds.sh clear                           stop the hold loop and the watchdog (recorded pids), remove pipe + anchor
#   mac-holds.sh show                            dnctl list + the anchor's rules + pf status + watchdog pid
#   mac-holds.sh holds                           the holds applied so far (one JSON line each)
# Profiles:
#   stall       4 ms base; every 5 s a 600 ms hold
#   wifi-away   from a Wi-Fi capture of a laptop away from its access point: 4 ms base, 2% random loss;
#               a 50-100 ms hold every 0.53 s at a fixed cadence; long holds of 300-580 ms (median ~455)
#               at irregular gaps (lognormal, median 3.4 s, clipped to 0.5-11 s); a long hold replaces
#               the short ones it overlaps. Fixed seed, so every run gets the same schedule
#               (wifi-away-schedule.jsonl here is `schedule wifi-away 900`, made with macOS /usr/bin/python3).
#   wifi-short, wifi-long, wifi-loss   ablations of wifi-away on the same schedule: only its short holds
#               (no loss), only its long holds (no loss), only its 2% loss (no holds)
#   wifi-loss-1 wifi-loss at 1% random loss (no holds): the loss the Reassembly row is read under
# How a hold queues and then bursts: dummynet queues are capped (100 slots / 1 MB, ~170 ms at 48 Mbps), so
# a zero-bandwidth hold would drop. Its delay line has no cap, and each packet's exit time is fixed when it
# enters (FIFO). So during a hold of H ms the delay steps down from 4+H ms (every 10 ms for holds under
# 150 ms, else 25 ms): a packet that enters at t leaves at about the hold's end, all together, then 4 ms
# again. Each hold's start and end go to the holds log on CLOCK_MONOTONIC (cmux-rd's protocol clock) and
# the wall clock.
set -u
ANCHOR="com.apple/rd-synth-stall"
PIPE=7730
ST=/var/tmp/rd-synth-stall
PY=${MAC_HOLDS_PY:-/usr/bin/python3}
DNCTL=${MAC_HOLDS_DNCTL:-dnctl}   # tests put a stub here
PROFILES="stall wifi-away wifi-short wifi-long wifi-loss wifi-loss-1"
BASE_DELAY_MS=4
# Never configure a dummynet pipe with a delay under 1 ms. A zero-delay pipe reinjects packets inside
# the network stack; five such pipes behind pf probability rules, with rd traffic, overflowed the kernel
# stack and panicked a macOS 27 fleet Mac twice on 2026-11-16 ("Invalid kernel stack pointer (probable
# overflow)", panicked task cmux-rd). Both places that configure the pipe (pipe_config here and delay()
# in the hold loop) refuse it, so a later profile cannot bring it back.
MIN_DELAY_MS=1

pipe_config() {  # DELAY_MS PLR: configure the pipe, refusing a delay under MIN_DELAY_MS
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$MIN_DELAY_MS" ] \
    || { echo "refusing dummynet delay '$1' ms: under $MIN_DELAY_MS ms panics macOS (see MIN_DELAY_MS)" >&2; return 1; }
  "$DNCTL" pipe "$PIPE" config delay "$1" plr "$2"
}

hold_loop() {  # PLR SCHEDULE OUT MAX_S BASE_MS: apply the schedule's holds (see "How a hold queues")
  "$PY" -I - "$PIPE" "$1" "$2" "$3" "$4" "$5" "$MIN_DELAY_MS" "$DNCTL" <<'PYEOF'
import json, subprocess, sys, time
pipe, plr, sched, out = sys.argv[1:5]
max_s, base_ms, min_ms, dnctl = float(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]), sys.argv[8]
mono_us = lambda: time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1000
def delay(ms):
    # Under MIN_DELAY_MS a dummynet pipe panics macOS (see MIN_DELAY_MS in mac-holds.sh): stop instead.
    if int(ms) < min_ms:
        sys.exit(f"refusing dummynet delay {int(ms)} ms: under {min_ms} ms panics macOS (see MIN_DELAY_MS)")
    subprocess.run([dnctl, "pipe", pipe, "config", "delay", str(int(ms)), "plr", plr], stdout=subprocess.DEVNULL)
holds = [json.loads(line) for line in open(sched)]
t_base = time.monotonic()
with open(out, "a") as log:
    for h in holds:
        hold = h["hold_ms"]
        wait = t_base + h["start_s"] - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        t0 = time.monotonic()
        rec = {"kind": h["kind"], "hold_ms": hold, "start_mono_us": mono_us(), "start_wall_ms": int(time.time() * 1000)}
        step = 10.0 if hold < 150 else 25.0
        j = 0
        while j * step < hold:
            delay(base_ms + hold - j * step)
            j += 1
            time.sleep(max(0.0, t0 + min(j * step, hold) / 1000 - time.monotonic()))
        delay(base_ms)
        rec.update({"end_mono_us": mono_us(), "end_wall_ms": int(time.time() * 1000)})
        log.write(json.dumps(rec) + "\n"); log.flush()
# The base delay and loss stay on until MAX_S (or clear), also with no holds left (wifi-loss has none).
time.sleep(max(0.0, t_base + max_s - time.monotonic()))
PYEOF
}

plr_of() { case "$1" in wifi-away|wifi-loss) echo 0.02 ;; wifi-loss-1) echo 0.01 ;; *) echo 0 ;; esac; }
# A recorded pid may be stale (a killed watchdog, a reboot): act on it only while it still runs this
# script's watchdog, its hold loop or a dnctl the loop started.
ours() {
  [ -n "${1:-}" ] || return 1
  case "$(ps -o command= -p "$1" 2>/dev/null)" in
    *mac-holds.sh\ _watchdog*|*[Pp]ython*" -I - $PIPE "*|"dnctl pipe $PIPE "*) return 0 ;;  # /usr/bin/python3 may exec the CLT Python
  esac
  return 1
}
known() { case " $PROFILES " in *" $1 "*) return 0 ;; esac; echo "unknown profile $1 (one of: $PROFILES)" >&2; return 1; }

schedule() {  # PROFILE MAX_S: one {"start_s", "hold_ms", "kind"} line per hold, in order
  "$PY" -I - "$1" "$2" <<'PYEOF'
import json, math, random, sys
prof, max_s = sys.argv[1], float(sys.argv[2])
rng = random.Random(20261116)
holds = []
if prof == "stall":
    t = 4.4
    while t < max_s:
        holds.append((t, 600.0, "stall")); t += 5.0
elif prof.startswith("wifi-"):
    longs, t = [], 0.0
    while t < max_s:
        t += min(11.0, max(0.5, math.exp(rng.gauss(math.log(3.4), 0.6))))
        longs.append((t, rng.triangular(300.0, 580.0, 472.0)))
    k = 1
    while k * 0.53 < max_s:
        s = k * 0.53
        if not any(ls - 0.11 <= s <= ls + lh / 1000 + 0.01 for ls, lh in longs):
            holds.append((s, rng.uniform(50.0, 100.0), "short"))
        k += 1
    holds += [(ls, lh, "long") for ls, lh in longs]
    keep = {"wifi-short": ("short",), "wifi-long": ("long",), "wifi-loss": (), "wifi-loss-1": ()}.get(prof, ("short", "long"))
    holds = sorted(h for h in holds if h[2] in keep)
for start, hold, kind in holds:
    if start <= max_s:
        print(json.dumps({"start_s": round(start, 3), "hold_ms": round(hold, 1), "kind": kind}))
PYEOF
}

clear_all() {
  pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
  dnctl pipe delete "$PIPE" >/dev/null 2>&1
  if [ -s "$ST/token" ]; then pfctl -X "$(cat "$ST/token")" >/dev/null 2>&1; rm -f "$ST/token"; fi
  echo "$(date -u +%FT%TZ) cleared" >> "$ST/log"
}

case "${1:-}" in
  schedule)
    known "${2:-}" || exit 2
    schedule "$2" "${3:?MAX_S}"
    exit
    ;;
  _plr_of)       # PROFILE: its random loss (tests)
    known "${2:-}" || exit 2; plr_of "$2"; exit
    ;;
  _pipe_config)  # DELAY_MS PLR (tests: with MAC_HOLDS_DNCTL set to a stub)
    pipe_config "$2" "$3"; exit
    ;;
  _hold_loop)    # PLR SCHEDULE OUT MAX_S BASE_MS (tests: with MAC_HOLDS_DNCTL set to a stub)
    hold_loop "$2" "$3" "$4" "$5" "$6"; exit
    ;;
esac
mkdir -p "$ST"; chmod 700 "$ST"

case "${1:-}" in
  start)
    prof=$2 max=$3; shift 3
    known "$prof" || exit 2
    [ "$#" -ge 1 ] || { echo "no peer address given" >&2; exit 2; }
    for p in "$@"; do
      [[ "$p" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo "not an IPv4 address: $p" >&2; exit 2; }
    done
    ours "$(cat "$ST/watchdog.pid" 2>/dev/null)" && { echo "watchdog already running" >&2; exit 1; }
    clear_all
    : > "$ST/holds.jsonl"
    schedule "$prof" "$max" > "$ST/schedule.jsonl" || { echo "no schedule" >&2; exit 1; }
    tok=$(pfctl -E 2>&1 | sed -n 's/^Token : //p')
    [ -n "$tok" ] || { echo "pfctl -E gave no token" >&2; clear_all; exit 1; }
    echo "$tok" > "$ST/token"
    pipe_config "$BASE_DELAY_MS" "$(plr_of "$prof")" >/dev/null || { clear_all; exit 1; }
    echo "dummynet out quick proto { tcp udp icmp } from any to { $* } pipe $PIPE" \
      | pfctl -a "$ANCHOR" -f - 2>&1 | grep -v -e "ALTQ" -e "^$" -e "flushing of rules" -e "present in the main ruleset"
    [ "$(pfctl -a "$ANCHOR" -s dummynet 2>/dev/null | wc -l)" -ge 1 ] || { echo "anchor did not load" >&2; clear_all; exit 1; }
    echo "$(date -u +%FT%TZ) start $prof max $max peers $*" >> "$ST/log"
    nohup /bin/bash "$0" _watchdog "$prof" "$max" </dev/null >>"$ST/log" 2>&1 &
    echo $! > "$ST/watchdog.pid"
    echo "started $prof token $tok watchdog $(cat "$ST/watchdog.pid") holds $(wc -l < "$ST/schedule.jsonl") peers { $* }"
    ;;
  _watchdog)
    prof=$2 max=$3
    trap '[ -s "$ST/py.pid" ] && kill -TERM "$(cat "$ST/py.pid")" 2>/dev/null; clear_all; rm -f "$ST/watchdog.pid" "$ST/py.pid"; exit 0' TERM INT HUP
    # The hold loop runs in Python for its timing and the monotonic clock.
    hold_loop "$(plr_of "$prof")" "$ST/schedule.jsonl" "$ST/holds.jsonl" "$max" "$BASE_DELAY_MS" &
    echo $! > "$ST/py.pid"
    wait $!
    clear_all
    rm -f "$ST/watchdog.pid" "$ST/py.pid"
    ;;
  clear)
    # The hold loop first, and wait until it and any dnctl it started have exited: a `dnctl pipe config`
    # still running after the pipe is deleted would create it again. Then the watchdog, then the pipe.
    stop_pid() {  # PID: TERM, wait up to 3 s, then KILL and wait; never a pid that is no longer ours
      ours "$1" || return 0
      kill -TERM "$1" 2>/dev/null
      for _ in $(seq 15); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
      kill -KILL "$1" 2>/dev/null; for _ in $(seq 10); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
      echo "pid $1 did not exit" >&2; return 1
    }
    pp=$(cat "$ST/py.pid" 2>/dev/null); wp=$(cat "$ST/watchdog.pid" 2>/dev/null)
    [ -n "$pp" ] && { kids=$(pgrep -P "$pp"); stop_pid "$pp"; for c in $kids; do stop_pid "$c"; done; }
    [ -n "$wp" ] && stop_pid "$wp"
    rm -f "$ST/py.pid" "$ST/watchdog.pid"
    clear_all
    sleep 0.5
    dnctl list 2>/dev/null | grep -q "^0$PIPE:" && { echo "pipe came back; clearing again" >&2; clear_all; }
    for p in $pp $wp; do ours "$p" && echo "still running: $p" || echo "exited: $p"; done
    echo "holds: $(wc -l < "$ST/holds.jsonl" 2>/dev/null || echo 0)"
    ;;
  show)
    echo "== dnctl list"; dnctl list
    echo "== pfctl -a $ANCHOR -s dummynet"; pfctl -a "$ANCHOR" -s dummynet 2>/dev/null
    echo "== pf status"; pfctl -s info 2>/dev/null | head -1
    echo "== watchdog"; cat "$ST/watchdog.pid" 2>/dev/null
    ;;
  holds) cat "$ST/holds.jsonl" 2>/dev/null ;;
  *) echo "usage: mac-holds.sh schedule|start PROFILE MAX_S [PEER_IP...] | clear | show | holds  (profiles: $PROFILES)" >&2; exit 2 ;;
esac
