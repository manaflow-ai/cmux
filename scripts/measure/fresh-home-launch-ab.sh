#!/usr/bin/env bash
# A fresh-home launch A/B in ONE measure step: the base commit's app and the head commit's app, launched
# back to back in interleaved rounds (base, head, base, head, ...) on the same worker, so both arms see the
# same host state, and the bench Mac is held by one step instead of one per launch.
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
#     --script scripts/measure/fresh-home-launch-ab.sh --ref <this script's sha> \
#     --arg=base=<sha> --arg=head=<sha> [--arg=rounds=3] [--arg=warm=N] \
#     --artifact .build/fresh-home-launch-ab/report.tgz --timeout 7200
#   --arg=base=SHA   arm A, the commit to compare against (40 hex)
#   --arg=head=SHA   arm B, the measured commit (40 hex)
#   --arg=rounds=N   launches per arm (default 3, at most 10)
#   --arg=warm=N     after each round's fresh-home launch, N warm launches from the same HOME (default 0, at
#                    most 10; fresh-home-launch.sh warm=N): what a person's next launches see, caches filled
# Each launch is scripts/measure/fresh-home-launch.sh ref=SHA from this checkout (an empty HOME, a tagged
# Debug app, Home must render): its smoke report is kept per launch, and the step prints each launch's
# times and the medians per arm, all in ms after process start, plus the wall time to Home:
#   FRESH-HOME-AB launch <arm> <round> rc <N> main_start <ms> first_frame <ms> home_first_page <ms> rendered_s <s>
#   FRESH-HOME-AB median <arm> n <N> main_start <ms> first_frame <ms> home_first_page <ms> rendered_s <s>
# and with warm=N, each warm launch and the warm medians, with the Chief marks (home.chief_cached: Home drew
# the cached Chief; home.chief_found: this launch's Chief lookup found it):
#   FRESH-HOME-AB warm <arm> <round>.<k> first_frame <ms> home_first_page <ms> chief_cached <ms> chief_found <ms> ...
#   FRESH-HOME-AB warm-median <arm> n <N> first_frame <ms> (min-max) home_first_page <ms> (min-max) ...
# A launch whose step $TMPDIR check found files (exit 5) still rendered Home: its times count, and the line
# says so. The verdict: exit 0 every launch passed, 1 a launch failed (crashed or never rendered Home, or
# left files), 3 none could run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$PWD"
base="" head="" rounds=3 warm=0
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    warm=*) warm="${arg#warm=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= must be 40-hex commits" >&2; exit 2; }
[[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 && rounds <= 10 )) || { echo "rounds= must be 1 to 10" >&2; exit 2; }
[[ "$warm" =~ ^[0-9]+$ ]] && (( warm <= 10 )) || { echo "warm= must be 0 to 10" >&2; exit 2; }
out="$here/.build/fresh-home-launch-ab"
rm -rf "$out" && mkdir -p "$out"
one="$here/.build/fresh-home-launch"
for i in $(seq 1 "$rounds"); do
  for arm in base head; do
    ref="$base"; [ "$arm" = head ] && ref="$head"
    # The launch's own lines stream to the step's log (a silent step looks hung) and to its own file.
    bash "$here/scripts/measure/fresh-home-launch.sh" "ref=$ref" "warm=$warm" 2>&1 | tee "$out/$arm-$i.log"
    rc=${PIPESTATUS[0]}
    mkdir -p "$out/$arm-$i"
    [ -d "$one/smoke" ] && cp -R "$one/smoke" "$out/$arm-$i/smoke"
    echo "$rc" > "$out/$arm-$i/rc"
  done
done
python3 -I - "$out" "$rounds" <<'PY'
import json, os, statistics, sys
out, rounds = sys.argv[1], int(sys.argv[2])
# 0 passed; 5 passed, but the step's $TMPDIR check found files: Home rendered, so its times count.
TIMED = (0, 5)
WARM_KEYS = ("first_frame", "home_first_page", "chief_cached", "chief_found", "rendered_s")
summary, codes = {}, []
def since_start(marks, key):
    v, s = marks.get(key), marks.get("main_start")
    return None if v is None or s is None else round(v - s, 1)
def spread(vals):
    return f"{round(statistics.median(vals), 1)} ({min(vals)}-{max(vals)})" if vals else "None"
for arm in ("base", "head"):
    rows, warms = [], []
    for i in range(1, rounds + 1):
        d = os.path.join(out, f"{arm}-{i}")
        rc = int(open(os.path.join(d, "rc")).read().strip() or 3)
        codes.append(rc)
        row = {"round": i, "rc": rc}
        try:
            r = json.load(open(os.path.join(d, "smoke", "report.json")))
            m = r.get("marks") or {}
            row.update(main_start=m.get("main_start"), first_frame=since_start(m, "first_window_frame_committed"),
                       home_first_page=since_start(m, "home.first_page"), rendered_s=r.get("rendered_at"),
                       tmpdir_left=len(r.get("tmpdir_left") or []))
            for k, w in enumerate(r.get("warm") or [], 1):
                wm = w.get("marks") or {}
                warms.append({"round": f"{i}.{k}", "exit": w.get("exit"), "rendered_s": w.get("rendered_at"),
                              "first_frame": since_start(wm, "first_window_frame_committed"),
                              "home_first_page": since_start(wm, "home.first_page"),
                              "chief_cached": since_start(wm, "home.chief_cached"),
                              "chief_found": since_start(wm, "home.chief_found")})
        except (OSError, ValueError):
            pass
        rows.append(row)
        print("FRESH-HOME-AB launch", arm, i, "rc", rc,
              *[f"{k} {row.get(k)}" for k in ("main_start", "first_frame", "home_first_page", "rendered_s", "tmpdir_left")],
              *(["(step TMPDIR check found files)"] if rc == 5 else []))
    for w in warms:
        print("FRESH-HOME-AB warm", arm, w["round"], *[f"{k} {w.get(k)}" for k in WARM_KEYS], "exit", w["exit"])
    med = {}
    for k in ("main_start", "first_frame", "home_first_page", "rendered_s"):
        vals = [r[k] for r in rows if r.get(k) is not None and r["rc"] in TIMED]
        med[k] = round(statistics.median(vals), 3) if vals else None
    n = sum(1 for r in rows if r["rc"] in TIMED)
    print("FRESH-HOME-AB median", arm, "n", n, *[f"{k} {v}" for k, v in med.items()])
    good = [w for w in warms if w["exit"] is None and w["rendered_s"] is not None]
    warm_med = {k: spread([w[k] for w in good if w.get(k) is not None]) for k in WARM_KEYS}
    if warms:
        print("FRESH-HOME-AB warm-median", arm, "n", len(good), *[f"{k} {v}" for k, v in warm_med.items()])
    summary[arm] = {"launches": rows, "median": med, "passed": n, "warm": warms, "warm_median": warm_med}
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
sys.exit(0 if all(c == 0 for c in codes) else 3 if all(c == 3 for c in codes) else 1)
PY
status=$?
echo "FRESH-HOME-AB verdict exit $status base $base head $head rounds $rounds warm $warm"
# Packed beside the folder, then moved in: a tar of the folder it writes into reads its own output.
tar -czf "$out.tgz" -C "$out" . && mv "$out.tgz" "$out/report.tgz"
exit $status
