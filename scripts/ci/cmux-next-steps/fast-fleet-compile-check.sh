#!/usr/bin/env bash
# cmux-next.yml job `release-compile-fast`, step "Run the fast fleet compile check". Moved out of the workflow to keep it under
# GitHub's workflow file size limit (tests/test_ci_workflow_file_size.py); its env: stays in the workflow.
set -uo pipefail
# Why: note-482
if [[ -z "$GATEWAY" ]]; then
  [[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "verdict=unavailable" >> "$GITHUB_OUTPUT"; exit 0; }
  reply="$RUNNER_TEMP/compile-check.json"
  deadline=$((SECONDS + ${WAIT_SECONDS:-1200}))
  [[ "${SEEN:-}" != none ]] || deadline=$SECONDS  # no second wait: the Mac fallback starts now
  state="" reads=0 last="" ok_at=$SECONDS  # ok_at: the last usable answer (200 or 404), from before the first read
  # Why: note-457
  for probe in 1 2; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 \
      "$RESULTS/$REF?repo=${REPO/\//%2F}&wait=1" 2>/dev/null)" || true
    [[ "${code:=000}" =~ ^(000|52[0-9]|530)$ ]] || { [[ "$code" =~ ^(200|404)$ ]] && ok_at=$SECONDS; break; }
    (( probe == 2 )) && { state="results service down (HTTP $code)"; deadline=$SECONDS; } || sleep "${PROBE_GAP:-30}"
  done
  # Why: note-82 (compile-status: the results service down)
  while [[ "$state" != "results service down"* ]]; do
    # Why: note-517
    end=$(( deadline < ok_at + ${BAD_BOUND:-300} ? deadline : ok_at + ${BAD_BOUND:-300} ))
    left=$((end - SECONDS))
    (( left > 1 )) || break
    wait=$(( left > 60 ? left - 30 : left / 2 )); wait=$(( wait < 1800 ? wait : 1800 ))
    code="$(bash scripts/ci/timeout.sh "$left" curl -sS -o "$reply" -w '%{http_code}' --connect-timeout 10 \
      --max-time "$left" "$RESULTS/$REF?repo=${REPO/\//%2F}&wait=$wait")" || true
    case "${code:=000}" in
      200) reads=$((reads + 1)) ok_at=$SECONDS last=""
        state="$(jq -r --arg sha "$REF" --arg repo "$REPO" '
          if .sha != $sha or .repo != $repo or .recipe_version != 2 or .configuration != "release-onone"
          then "mismatch" else (.state // "") end' "$reply" 2>/dev/null || echo unreadable)"
        echo "read $reads: $state"
        case "$state" in pass|fail|unavailable|mismatch|unreadable|superseded) break ;; esac ;;
      404) ok_at=$SECONDS last=""; echo "no fleet result for $REF yet" ;;
      *) last="HTTP $code" ;;
    esac
    gap=$(( end - SECONDS < ${READ_GAP:-30} ? end - SECONDS : ${READ_GAP:-30} ))
    (( gap <= 0 )) || sleep "$gap"
  done
  [[ "$state" == "results service down"* || -z "$last" ]] || state="results service down ($last for $((SECONDS - ok_at)) s)"
  # Why: note-554
  # Why: 2026-11-27-release-compile-stale-push.md (any no-verdict state, not only "superseded": undo with
  # vars.CMUX_NEXT_STALE_PUSH_MAC_FALLBACK = '0')
  if [[ "$state" == superseded || "$state" != pass && "$state" != fail && "${STALE_PUSH_GATE:-1}" != 0 ]]; then
    head=""
    if [[ "${SUPERSEDED_GATE:-1}" != 0 ]]; then
      head="$(bash scripts/ci/timeout.sh 30 git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=15 ls-remote \
        "${GITHUB_SERVER_URL:-https://github.com}/$REPO.git" "${GITHUB_REF:-refs/heads/feat-cmux-next}" 2>/dev/null |
        awk 'NR==1{print $1}')" || head=""
    fi
    if [[ "$head" =~ ^[0-9a-f]{40}$ && "$head" != "$REF" ]]; then
      echo "::notice title=Fast fleet compile check::superseded push $REF: the branch head is $head, whose tip check covers this push; no Mac fallback"
      echo "verdict=superseded" >> "$GITHUB_OUTPUT"
      exit 0
    fi
  fi
  case "$state" in
    pass) verdict=pass; echo "The build fleet compiled and linked the app at $REF in Release (-Onone) on Linux." ;;
    fail) verdict=fail; echo "::error title=Fast fleet compile check::the build fleet's Release compile failed at $REF; see cmux-next/compile's log: $(jq -r '.log_url // empty' "$reply" 2>/dev/null)" ;;
    *) verdict=unavailable; echo "::warning title=mac fallback::no fleet verdict for $REF (${state:-no result}); the Mac fallback will run." ;;
  esac
  echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
  [[ "$verdict" != fail ]]
  exit
fi
echo "::warning title=mac fallback::compile-status gave no clean verdict; this push's check runs from Mac gateway runner $RUNNER_NAME"
client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
if ! [[ -x "$client" ]]; then
  echo "::warning title=mac fallback::cmux-ci is not installed on $RUNNER_NAME; the Mac fallback will run."
  echo "verdict=unavailable" >> "$GITHUB_OUTPUT"
  exit 0
fi
# Why: note-458
if ! "$client" compile-check --help 2>/dev/null | grep -q -- '--release'; then
  echo "::warning title=mac fallback::the fleet client has no Release profile; the Mac fallback will run."
  echo "verdict=unavailable" >> "$GITHUB_OUTPUT"
  exit 0
fi
# Why: note-518
word=none
if [[ "${SEEN:-}" != none && -f scripts/ci/fleet_compile_result.py ]] && command -v python3 >/dev/null; then
  word="$(python3 scripts/ci/fleet_compile_result.py --sha "$REF" --repo "$GITHUB_REPOSITORY" --wait 900 --no-record 300)" || word=none
fi
status=0
case "$word" in
  pass) echo "The tip check compiled and linked the app at $REF in Release (-Onone); not compiled again." ;;
  fail) status=1 ;;
  # Why: 2026-11-25-fleet-compile-down.md
  down) status=69 ;;
  *) "$client" compile-check --ref "$REF" --app --release \
       --timeout 1200 --queue-timeout 300 || status=$? ;;
esac
case "$status" in
  0) verdict=pass ;;
  69|75|124) verdict=unavailable; echo "::warning title=mac fallback::the fleet gave no verdict (exit $status); the Mac fallback will run." ;;
  *) verdict=fail; echo "::error title=Fast fleet compile check::the fleet compile check failed at $REF (exit $status)." ;;
esac
echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
[[ "$verdict" != fail ]]
