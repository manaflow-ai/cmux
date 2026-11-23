#!/usr/bin/env bash
# Agent chat typing A/B in ONE measure step: the perf cron's own chat measurement (scripts/measure/split-spring.sh
# --suite=budgets --only=acp on a 120 Hz virtual display, the chat-anim part of scripts/cmux-next/perf-cron.py, which
# writes the acp.<engine>.typing.to_frame rows) for the base commit's app and the head commit's app, in interleaved
# rounds (base, head, base, head, ...) on the same Mac, so both arms see the same host state.
#   cmux-ci run --class exclusive --measurement --label bench \
#     --script scripts/measure/chat-typing-ab.sh --ref <this script's sha> \
#     --arg=base=<sha> --arg=head=<sha> [--arg=rounds=2] \
#     --artifact .build/chat-typing-ab/report.tgz --timeout 7200
#   --arg=base=SHA   arm A, the commit to compare against (40 hex)
#   --arg=head=SHA   arm B, the measured commit (40 hex)
#   --arg=rounds=N   measurements per arm (default 2, at most 6)
#   --arg=hz=N       the virtual display's refresh (default 120; 0 measures on the host's own display)
# The step holds ONE virtual main display for every round, built from this script's own checkout
# (scripts/ci/frame-pacing/vdisplay.m), so both arms measure on the same display whatever their commits' helper
# (an arm's own helper before this change reported 120 Hz while pages drew at 60 Hz on aws-m4pro-7: step 1f3cd183,
# trackpad frames p50 17 ms for both engines). The arms then run without --vdisplay; if this display cannot be made,
# the arms fall back to their own --vdisplay and the step says so.
# Every to_frame is only as good as the refresh it was measured at, so the step reports the refresh it measured:
#   CHAT-TYPING-AB display requested_hz <hz> line <the helper's ready line: CVDisplayLink ms, drawn=<ms a window's
#     CADisplayLink drew at>, maxfps=<NSScreen.maximumFramesPerSecond>>
#   per round and arm, acp.<engine>.frame_interval p50/p95: the pages' own measured frame interval (the trackpad and
#     wheel ticks of the bench), beside that engine's to_frame rows
#   CHAT-TYPING-AB REFRESH-MISMATCH ... when an engine drew slower than the requested refresh (its frame interval
#     p50 over 1.25 x 1000 / hz): those to_frame rows are numbers at that slower rate.
# Each arm is its own git worktree at its commit, measured by that commit's split-spring.sh with --app-cache: the
# first round builds the arm's app, later rounds reuse it. The app-cache entries this step made, the worktrees and
# the benches' scratch folders in TMPDIR are removed at the end; free disk is printed at the start and the end.
# The step prints, per round and arm, each engine's typing rows (ms from keydown to the next frame, and to its paint;
# from 46e6d692 on also to_listener, keydown to the page's first listener, and to_work, to the edit and its render done),
# then the median of the rounds' p50 and p95 per arm and the head - base delta:
#   CHAT-TYPING-AB round <arm> <round> rc <N> <row> p50 <ms> p95 <ms> ...
#   CHAT-TYPING-AB median <arm> n <N> <row> p50 <ms> p95 <ms> ...
#   CHAT-TYPING-AB delta <row> p50 <ms> p95 <ms>
# The verdict: exit 0 every round measured, 1 a round failed, 3 none could run, 4 every round measured but an
# engine drew slower than the requested refresh (REFRESH-MISMATCH).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$PWD"
base="" head="" rounds=2 hz=120
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    hz=*) hz="${arg#hz=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= must be 40-hex commits" >&2; exit 2; }
[[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 && rounds <= 6 )) || { echo "rounds= must be 1 to 6" >&2; exit 2; }
[[ "$hz" =~ ^[0-9]+$ ]] && (( hz == 0 || (hz >= 30 && hz <= 240) )) || { echo "hz= must be 0 or 30 to 240" >&2; exit 2; }
out="$here/.build/chat-typing-ab"
rm -rf "$out" && mkdir -p "$out"
# A cancelled or timed-out step gets SIGTERM, which skips an EXIT trap unless the signal is trapped.
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
vdisplay_pid="" scratch="" cache_dir="${CI_SHARED_CACHE_DIR:+$CI_SHARED_CACHE_DIR/split-spring-apps}"
cache_before="$( [ -n "$cache_dir" ] && ls -1 "$cache_dir" 2>/dev/null | sort)"
tmp_root="${TMPDIR:-/tmp}"; tmp_root="${tmp_root%/}"
tmp_before="$(ls -A "$tmp_root" 2>/dev/null | sort)"
cleanup() {
  local code=$?
  if [ -n "$vdisplay_pid" ]; then
    kill "$vdisplay_pid" 2>/dev/null  # the helper this step started, by its PID
    wait "$vdisplay_pid" 2>/dev/null
  fi
  if [ -n "$scratch" ]; then
    for arm in base head; do
      [ -d "$scratch/$arm" ] && git -C "$here" worktree remove --force "$scratch/$arm" >/dev/null 2>&1
    done
    rm -rf "$scratch"
    git -C "$here" worktree prune >/dev/null 2>&1
  fi
  # Only the app-cache entries this step made (the arms' apps), never one an earlier step left.
  if [ -n "$cache_dir" ] && [ -d "$cache_dir" ]; then
    comm -13 <(printf '%s\n' "$cache_before") <(ls -1 "$cache_dir" 2>/dev/null | sort) | sed '/^$/d' |
      while read -r made; do rm -rf "${cache_dir:?}/$made"; done
  fi
  # The benches' scratch folders (agent-engine-bench.py, bench_launch.py) that appeared during this step.
  comm -13 <(printf '%s\n' "$tmp_before") <(ls -A "$tmp_root" 2>/dev/null | sort) | sed '/^$/d' |
    while read -r made; do
      case "$made" in agent-engine-*|bench-launch-split-spring-*|bench-split-spring-*) rm -rf "${tmp_root:?}/$made" ;; esac
    done
  local left
  left="$(comm -13 <(printf '%s\n' "$tmp_before") <(ls -A "$tmp_root" 2>/dev/null | sort) | sed '/^$/d')"
  [ -n "$left" ] && echo "CHAT-TYPING-AB left in $tmp_root: $(echo "$left" | head -n 20 | tr '\n' ' ')"
  echo "CHAT-TYPING-AB disk free after: $(df -h "$here" | awk 'NR==2 {print $4}')"
  exit "$code"
}
trap cleanup EXIT
echo "CHAT-TYPING-AB disk free before: $(df -h "$here" | awk 'NR==2 {print $4}')"
echo "CHAT-TYPING-AB host $(hostname -s) macOS $(sw_vers -productVersion 2>/dev/null) base $base head $head rounds $rounds"
# The benches launch the app, which draws only in this account's GUI session. Without one every round measures
# nothing, after both arms' app builds (2026-11-18: cmux21-23, the austin minis and a display mini each spent about an
# hour, then "no-gui-session" and 0 rounds), so check before building (the bench_launch session rule).
if ! session="$(python3 scripts/cmux-next/bench_launch.py session 2>&1)"; then
  echo "CHAT-TYPING-AB no-gui-session: $session" >&2
  echo "CHAT-TYPING-AB verdict exit 3 base $base head $head rounds $rounds"
  exit 3
fi
# Steps run with a per-step HOME; node and cargo for the app build live under the account's real home.
# The worker puts the bun webviews/package.json pins (<fleet>/tools/bun-<pin>) first on PATH; the
# account's ~/.bun/bin may hold an older one, so that pinned bun goes back in front after the prepends
# (step 33bef005, 2026-11-14: "webviews needs bun 1.4.4 or newer ...; /Users/cmux/.bun/bin/bun is bun
# 1.4.2", every round failed).
pinned_bun="$(command -v bun 2>/dev/null || true)"
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
[ -n "$pinned_bun" ] && export PATH="$(dirname "$pinned_bun"):$PATH"
echo "CHAT-TYPING-AB bun $(command -v bun) $(bun --version 2>/dev/null)"
if [ -n "$account_home" ]; then
  [ -z "${RUSTUP_HOME:-}" ] && [ -d "$account_home/.rustup" ] && export RUSTUP_HOME="$account_home/.rustup"
  [ -z "${CARGO_HOME:-}" ] && [ -d "$account_home/.cargo" ] && export CARGO_HOME="$account_home/.cargo"
fi
scratch="$(mktemp -d)"
for arm in base head; do
  ref="$base"; [ "$arm" = head ] && ref="$head"
  # A fleet step's checkout has no origin: try it, then the worker's mirror, then GitHub (a PR head is fetchable by sha).
  if ! git cat-file -e "$ref^{commit}" 2>/dev/null; then
    depth=()
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
    for remote in origin /Users/Shared/cmux-build-fleet/git/cmux.git https://github.com/manaflow-ai/cmux.git; do
      git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$ref" 2>/dev/null && break
    done
  fi
  git worktree add --quiet --detach "$scratch/$arm" "$ref" || { echo "CHAT-TYPING-AB cannot check out $arm $ref" >&2; exit 3; }
done
# One virtual main display for the whole step, from this checkout's helper (see the header). Its ready line says
# what the display really does: the CVDisplayLink interval, and drawn=, the interval a window on it is drawn at.
arm_display=()
display_line="host display (hz=0)"
if (( hz > 0 )); then
  vd="$out/vdisplay"
  mkdir -p "$vd/VDisplay.app/Contents/MacOS"
  display_line="error: the virtual display helper did not compile"
  if xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
      scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay" 2> "$vd/clang.err"; then
    cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
    codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
    "$vd/VDisplay.app/Contents/MacOS/VDisplay" "$hz" 14400 main 1920x1200 > "$vd/out" 2> "$vd/err" &
    vdisplay_pid=$!
    for _ in $(seq 40); do
      grep -q '^ready\|^error' "$vd/out" 2>/dev/null && break
      kill -0 "$vdisplay_pid" 2>/dev/null || break
      sleep 1  # bounded wait for the helper's own ready line
    done
    display_line="$(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo "error: the virtual display never reported ($(head -c 300 "$vd/err" 2>/dev/null || true))")"
  else
    display_line="$display_line: $(head -c 300 "$vd/clang.err" 2>/dev/null | tr '\n' ' ')"
  fi
  if [[ "$display_line" =~ ^ready\ ([0-9]+)\ [0-9.]+\ main=([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
    sleep 2  # let WindowServer settle the new main display before the first app opens on it
  else
    echo "CHAT-TYPING-AB VDISPLAY-FALLBACK no $hz Hz main display of this step ($display_line); the arms make their own"
    if [ -n "$vdisplay_pid" ]; then kill "$vdisplay_pid" 2>/dev/null; wait "$vdisplay_pid" 2>/dev/null; vdisplay_pid=""; fi
    arm_display=(--vdisplay="$hz")
  fi
fi
echo "CHAT-TYPING-AB display requested_hz $hz line $display_line"
echo "$display_line" > "$out/display.txt"
for i in $(seq 1 "$rounds"); do
  for arm in base head; do
    mkdir -p "$out/$arm-$i"
    # The arm's own split-spring.sh, as the perf cron's chat-anim part runs it (its lines stream to the step's log), on
    # this step's display (or, after a fallback, the arm's own --vdisplay).
    (cd "$scratch/$arm" && bash scripts/measure/split-spring.sh --app-cache ${arm_display[@]+"${arm_display[@]}"} --suite=budgets --only=acp) 2>&1 |
      tee "$out/$arm-$i/log" | grep -E "^split-spring:|PERF-BUDGETS|typing|first chat|error" | head -n 80
    echo "${PIPESTATUS[0]}" > "$out/$arm-$i/rc"
    for f in report.json acp.json display.txt; do
      [ -f "$scratch/$arm/artifacts/split-spring/$f" ] && cp "$scratch/$arm/artifacts/split-spring/$f" "$out/$arm-$i/$f"
    done
    rm -rf "$scratch/$arm/artifacts/split-spring"
  done
done
python3 -I - "$out" "$rounds" "$hz" <<'PY'
import json, os, re, statistics, sys
out, rounds, hz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ROW = re.compile(r"^acp\.[a-z0-9_-]+\.typing\.(to_frame|to_paint)$")
summary, codes = {}, []


def stat(obj):
    """p50 and p95 of a bench stat: a dict with p50/p95 (or _ms), or a list of samples (as perf-budgets.py p50_p95)."""
    if isinstance(obj, list):
        xs = sorted(x for x in obj if isinstance(x, (int, float)))
        if not xs:
            return None, None
        at = lambda q: xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]  # noqa: E731
        return round(at(0.5), 2), round(at(0.95), 2)
    if isinstance(obj, dict):
        p50 = next((obj[k] for k in ("p50", "p50_ms", "median") if isinstance(obj.get(k), (int, float))), None)
        p95 = next((obj[k] for k in ("p95", "p95_ms") if isinstance(obj.get(k), (int, float))), None)
        return p50, p95
    return None, None


for arm in ("base", "head"):
    per_round = []
    for i in range(1, rounds + 1):
        d = os.path.join(out, f"{arm}-{i}")
        try:
            rc = int(open(os.path.join(d, "rc")).read().strip() or 3)
        except (OSError, ValueError):
            rc = 3
        rows = {}
        try:
            for r in json.load(open(os.path.join(d, "report.json"))).get("rows") or []:
                if ROW.match(r.get("name", "")) and r.get("p95") is not None:
                    rows[r["name"]] = {"p50": r.get("p50"), "p95": r.get("p95")}
        except (OSError, ValueError, AttributeError):
            pass
        # Where a key's time goes before its frame, from the arm's acp.json (agent-engine-bench.py's summary, from
        # 46e6d692 on): to_listener (keydown to the page's first listener: the app, the web view and the page's main
        # thread) and to_work (to a task after the key's input event: the edit and its render). Not perf-budgets rows,
        # so an arm reads them whatever its perf-budgets.py; extra rows, never needed for a round to count.
        try:
            modes = json.load(open(os.path.join(d, "acp.json"))).get("modes") or {}
            for mode, r in modes.items():
                summ = (r.get("summary", r) if isinstance(r, dict) else {}) or {}
                for part in ("to_listener", "to_work"):
                    p50, p95 = stat(summ.get(f"typing_{part}"))
                    if p95 is not None:
                        rows[f"acp.{mode}.typing.{part}"] = {"p50": p50, "p95": p95}
                # The refresh this engine really drew at: the median of its tick runs' measured frame intervals
                # (trackpad and wheel, agent-engine-bench.py's ticks), so a to_frame read at 60 Hz says so.
                ticks = r.get("ticks") if isinstance(r, dict) else None
                p50s, p95s = [], []
                for run in ticks if isinstance(ticks, list) else []:
                    for kind in ("trackpad", "wheel"):
                        frames = (run.get(kind) or {}).get("frames") if isinstance(run, dict) else None
                        p50, p95 = stat(frames)
                        if p50 is not None:
                            p50s.append(p50)
                        if p95 is not None:
                            p95s.append(p95)
                if p50s:
                    rows[f"acp.{mode}.frame_interval"] = {
                        "p50": round(statistics.median(p50s), 2), "p95": round(statistics.median(p95s), 2) if p95s else None}
        except (OSError, ValueError, AttributeError):
            pass
        # A round counts when it ran and measured every typing row; a gate verdict on another row is not its failure.
        ok = any(ROW.match(name) for name in rows) and rc in (0, 1)
        codes.append(0 if ok else (rc or 1))
        per_round.append({"round": i, "rc": rc, "rows": rows})
        print("CHAT-TYPING-AB round", arm, i, "rc", rc,
              *[f"{k} p50 {v['p50']} p95 {v['p95']}" for k, v in sorted(rows.items())], flush=True)
    med = {}
    for name in sorted({k for r in per_round for k in r["rows"]}):
        vals = {s: [r["rows"][name][s] for r in per_round if name in r["rows"] and r["rows"][name][s] is not None]
                for s in ("p50", "p95")}
        med[name] = {s: round(statistics.median(v), 2) if v else None for s, v in vals.items()}
    summary[arm] = {"rounds": per_round, "median": med}
    print("CHAT-TYPING-AB median", arm, "n", sum(1 for r in per_round if r["rows"]),
          *[f"{k} p50 {v['p50']} p95 {v['p95']}" for k, v in med.items()])
for name in sorted(set(summary["base"]["median"]) & set(summary["head"]["median"])):
    a, b = summary["base"]["median"][name], summary["head"]["median"][name]
    d = {s: None if a[s] is None or b[s] is None else round(b[s] - a[s], 2) for s in ("p50", "p95")}
    print("CHAT-TYPING-AB delta", name, "p50", d["p50"], "p95", d["p95"])
# A to_frame is a number at the refresh the page drew at: an engine whose frames came slower than the requested
# refresh (its median frame interval over 1.25 periods, so 60 Hz frames on a 120 Hz request) fails the step's
# refresh check, named here, instead of passing as a 120 Hz reading.
slow = []
if hz > 0:
    period = 1000 / hz
    for arm in ("base", "head"):
        for name, v in summary[arm]["median"].items():
            if name.endswith(".frame_interval") and v["p50"] is not None and v["p50"] > 1.25 * period:
                slow.append(f"{arm} {name} p50 {v['p50']} ms ({round(1000 / v['p50'])} Hz)")
    for line in slow:
        print(f"CHAT-TYPING-AB REFRESH-MISMATCH requested {hz} Hz ({period:.2f} ms) but {line}: its to_frame rows are"
              " readings at that rate")
    if not any(name.endswith(".frame_interval") for arm in ("base", "head") for name in summary[arm]["median"]):
        print(f"CHAT-TYPING-AB REFRESH-UNMEASURED no engine reported its frame interval; the {hz} Hz request is unchecked")
summary["refresh"] = {"requested_hz": hz, "slow": slow}
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
code = 0 if all(c == 0 for c in codes) else 3 if all(c == 3 for c in codes) else 1
sys.exit(4 if code == 0 and slow else code)
PY
status=$?
echo "CHAT-TYPING-AB verdict exit $status base $base head $head rounds $rounds"
# Packed beside the folder, then moved in: a tar of the folder it writes into reads its own output.
tar -czf "$out.tgz" -C "$out" . && mv "$out.tgz" "$out/report.tgz"
exit $status
