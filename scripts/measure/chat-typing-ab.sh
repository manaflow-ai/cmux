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
# Each arm is its own git worktree at its commit, measured by that commit's split-spring.sh with --app-cache: the
# first round builds the arm's app, later rounds reuse it. The app-cache entries this step made, the worktrees and
# the benches' scratch folders in TMPDIR are removed at the end; free disk is printed at the start and the end.
# The step prints, per round and arm, each engine's typing rows (ms from keydown to the next frame, and to its paint),
# then the median of the rounds' p50 and p95 per arm and the head - base delta:
#   CHAT-TYPING-AB round <arm> <round> rc <N> <row> p50 <ms> p95 <ms> ...
#   CHAT-TYPING-AB median <arm> n <N> <row> p50 <ms> p95 <ms> ...
#   CHAT-TYPING-AB delta <row> p50 <ms> p95 <ms>
# The verdict: exit 0 every round measured, 1 a round failed, 3 none could run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$PWD"
base="" head="" rounds=2
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= must be 40-hex commits" >&2; exit 2; }
[[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 && rounds <= 6 )) || { echo "rounds= must be 1 to 6" >&2; exit 2; }
out="$here/.build/chat-typing-ab"
rm -rf "$out" && mkdir -p "$out"
# A cancelled or timed-out step gets SIGTERM, which skips an EXIT trap unless the signal is trapped.
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
scratch="" cache_dir="${CI_SHARED_CACHE_DIR:+$CI_SHARED_CACHE_DIR/split-spring-apps}"
cache_before="$( [ -n "$cache_dir" ] && ls -1 "$cache_dir" 2>/dev/null | sort)"
tmp_root="${TMPDIR:-/tmp}"; tmp_root="${tmp_root%/}"
tmp_before="$(ls -A "$tmp_root" 2>/dev/null | sort)"
cleanup() {
  local code=$?
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
# Steps run with a per-step HOME; bun, node and cargo for the app build live under the account's real home.
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
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
for i in $(seq 1 "$rounds"); do
  for arm in base head; do
    mkdir -p "$out/$arm-$i"
    # The arm's own split-spring.sh, as the perf cron's chat-anim part runs it (its lines stream to the step's log).
    (cd "$scratch/$arm" && bash scripts/measure/split-spring.sh --app-cache --vdisplay=120 --suite=budgets --only=acp) 2>&1 |
      tee "$out/$arm-$i/log" | grep -E "^split-spring:|PERF-BUDGETS|typing|first chat|error" | head -n 80
    echo "${PIPESTATUS[0]}" > "$out/$arm-$i/rc"
    for f in report.json acp.json display.txt; do
      [ -f "$scratch/$arm/artifacts/split-spring/$f" ] && cp "$scratch/$arm/artifacts/split-spring/$f" "$out/$arm-$i/$f"
    done
    rm -rf "$scratch/$arm/artifacts/split-spring"
  done
done
python3 -I - "$out" "$rounds" <<'PY'
import json, os, re, statistics, sys
out, rounds = sys.argv[1], int(sys.argv[2])
ROW = re.compile(r"^acp\.[a-z0-9_-]+\.typing\.(to_frame|to_paint)$")
summary, codes = {}, []
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
        # A round counts when it ran and measured every typing row; a gate verdict on another row is not its failure.
        ok = bool(rows) and rc in (0, 1)
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
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
sys.exit(0 if all(c == 0 for c in codes) else 3 if all(c == 3 for c in codes) else 1)
PY
status=$?
echo "CHAT-TYPING-AB verdict exit $status base $base head $head rounds $rounds"
# Packed beside the folder, then moved in: a tar of the folder it writes into reads its own output.
tar -czf "$out.tgz" -C "$out" . && mv "$out.tgz" "$out/report.tgz"
exit $status
