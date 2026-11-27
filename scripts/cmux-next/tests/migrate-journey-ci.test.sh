#!/usr/bin/env bash
# migrate-journey-ci.sh runs its cases at once: cmux is a stub whose apply sleeps 2 s and writes its HOME's
# ledger, the repos are local git repos. Five cases in well under five times one apply, one table row per case
# in case order, a red case fails the script, and MIGRATE_SERIAL=1 still runs them one after another.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../migrate-journey-ci.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$tmp/cmux" <<'STUB'
#!/usr/bin/env bash
# cmux migrate plan|apply SOURCE ...
[ "$1" = migrate ] || exit 2
case "$2" in
  plan) echo '{"result":{"source":{"kind":"devcontainer"},"projects":[{"name":"p"}]}}' ;;
  apply)
    sleep 2  # sleep-ok: a stand-in for the staging apply
    case "$3" in *"${STUB_RED:-no-red-case}"*) exit 1 ;; esac
    mkdir -p "$HOME/.cmux/migrate"
    echo '{"projects":{"p":{"started_ms":1000,"first_chat_ms":1500}}}' > "$HOME/.cmux/migrate/ledger.json"
    echo '{}' ;;
esac
STUB
chmod +x "$tmp/cmux"
repos=""
for n in one two three; do
  git init --quiet "$tmp/src/$n"
  git -C "$tmp/src/$n" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m init
  repos="$repos file://$tmp/src/$n"
done

run() { # run RUN_DIR [ENV...]: the script's exit status, summary at RUN_DIR/summary.md
  local dir="$1"; shift
  mkdir -p "$dir"
  env -u MIGRATE_SSH_HOST CMUX_PATH="$tmp/cmux" CMUX_DOGFOOD_STACK_EMAIL=e CMUX_DOGFOOD_STACK_PASSWORD=p \
    RUNNER_TEMP="$dir" GITHUB_STEP_SUMMARY="$dir/summary.md" MIGRATE_REPOS="$repos" \
    MIGRATE_T3_REPO="file://$tmp/src/one" "$@" bash "$script" > "$dir/out.log" 2>&1
}

start=$SECONDS
run "$tmp/par" || fail "all-pass run exited non-zero: $(cat "$tmp/par/out.log")"
took=$((SECONDS - start))
[ "$took" -lt 7 ] || fail "four 2 s cases took ${took}s: not at once"
rows="$(grep -c '| pass |' "$tmp/par/summary.md")"
[ "$rows" = 4 ] || fail "want 4 pass rows, got $rows: $(cat "$tmp/par/summary.md")"
order="$(grep '| pass |' "$tmp/par/summary.md" | cut -d'|' -f2 | tr -d ' ' | sed 's#(.*##; s#.*/##' | tr '\n' ' ')"
[ "$order" = "one two three t3code " ] || fail "rows out of case order: $order"
grep -q '| 500 |' "$tmp/par/summary.md" || fail "no first-chat ms from the case's own HOME ledger"
[ "$(wc -l < "$tmp/par/migrate-journey/results.jsonl")" = 4 ] || fail "results.jsonl wants 4 lines"

if run "$tmp/red" STUB_RED=/two; then fail "a red case left the script green"; fi
grep -q '/two | devcontainer | red |' "$tmp/red/summary.md" || fail "the red case has no red row: $(cat "$tmp/red/summary.md")"
[ "$(grep -c '| pass |' "$tmp/red/summary.md")" = 3 ] || fail "the other cases did not finish beside the red one"

start=$SECONDS
run "$tmp/ser" MIGRATE_SERIAL=1 || fail "serial run exited non-zero: $(cat "$tmp/ser/out.log")"
[ $((SECONDS - start)) -ge 8 ] || fail "MIGRATE_SERIAL=1 did not run the cases one after another"
[ "$(grep -c '| pass |' "$tmp/ser/summary.md")" = 4 ] || fail "serial run wants 4 pass rows"
echo "ok: migrate-journey-ci.sh cases run at once (${took}s for four 2 s applies), in-order rows, red propagates"
