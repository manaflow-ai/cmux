#!/usr/bin/env bash
# Poll the outer DMG submissions of a continuation run without a Mac, until
# each one is decided:
# - Accepted: staple it.
# - A DMG around the stapled app (state stapled_app=true) that is not Accepted
#   (still queued, refused, or not answered) at its recorded
#   stapled_submitted_at + CMUX_STAPLED_APP_FALLBACK_SECONDS (6 h): its
#   continuation ships the accepted first DMG
#   (resume-stapled-app-notarization.sh). Before that it is polled again.
# - Any other outer DMG still In Progress after CMUX_OUTER_POLL_SECONDS
#   (80 min) stalls and waits for a manual resume; a refused one fails.
# A failed query (poll-notary-submission.py exit 3) is an unknown answer and
# is polled again. The poll sleeps to the nearest deadline when that comes
# before the next interval, so a refused stapled-app DMG reaches its fallback.
# The job limit must cover CMUX_OUTER_POLL_BUDGET_SECONDS (357 min) plus setup.
# A stapled-app deadline that falls at most CMUX_OUTER_POLL_FALLBACK_SLACK_SECONDS
# (300 s) after the end of the budget (Apple refused the second DMG within a
# few minutes of its submission) is decided as due for the fallback: its
# continuation (resume-stapled-app-notarization.sh,
# CMUX_STAPLED_APP_DEADLINE_WAIT_SECONDS) waits until the deadline before it
# ships the first DMG. A later deadline is reported for a manual resume.
# A variant whose submission failed or could not be queried is recorded as
# failed; the others are still polled, and the script exits 1 at the end.
#
# Usage: poll-outer-notarizations.sh <metadata-root> <variants-file> <reports-dir>
# <metadata-root>/<variant>/ holds each downloaded metadata artifact. Needs
# SOURCE_RUN_ID, SOURCE_HEAD_SHA, SOURCE_RUN_ATTEMPT, CHANNEL and the ASC key.
# Writes decided=true|false and outer_variants=<JSON list of decided variants>
# to GITHUB_OUTPUT (or stdout).
set -uo pipefail
[ "$#" -eq 3 ] || { echo "usage: poll-outer-notarizations.sh <metadata-root> <variants-file> <reports-dir>" >&2; exit 2; }
ROOT="$1"
VARIANTS_FILE="$2"
REPORTS="$3"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POLL_TOOL="${CMUX_POLL_NOTARY_SUBMISSION_TOOL:-python3 $REPO_ROOT/scripts/ci/poll-notary-submission.py}"
FALLBACK_SECONDS="${CMUX_STAPLED_APP_FALLBACK_SECONDS:-21600}"
OUTER_POLL_SECONDS="${CMUX_OUTER_POLL_SECONDS:-4800}"
# A job may run 360 min; stop polling a little before that.
BUDGET_SECONDS="${CMUX_OUTER_POLL_BUDGET_SECONDS:-21420}"
INTERVAL_SECONDS="${CMUX_OUTER_POLL_INTERVAL_SECONDS:-300}"
SLACK_SECONDS="${CMUX_OUTER_POLL_FALLBACK_SLACK_SECONDS:-300}"
for value in "$FALLBACK_SECONDS" "$OUTER_POLL_SECONDS" "$BUDGET_SECONDS" "$INTERVAL_SECONDS" "$SLACK_SECONDS"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "poll-outer-notarizations.sh: every CMUX_*_SECONDS value must be a number of seconds" >&2; exit 2; }
done
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
now() { date +%s; }
mkdir -p "$REPORTS"
mapfile -t variants < "$VARIANTS_FILE"
if [ "${#variants[@]}" -eq 0 ]; then
  printf 'decided=false\nouter_variants=[]\n' >> "$OUT"
  exit 0
fi
start="$(now)"
declare -A state_of deadline_of result_of
for variant in "${variants[@]}"; do
  env_file="$REPORTS/$variant.env"
  if ! python3 "$REPO_ROOT/scripts/ci/resolve-notarization-recovery.py" \
      "$ROOT/$variant/cmux-nightly-notarization-recovery.json" "$SOURCE_RUN_ID" "$SOURCE_HEAD_SHA" "$CHANNEL" "$variant" \
      --run-attempt "$SOURCE_RUN_ATTEMPT" --strict --metadata-only > "$env_file"; then
    echo "outer recovery resolver failed for $variant" >&2
    exit 1
  fi
  state="$(awk -F= '$1 == "STATE_FILE" { print substr($0, index($0, "=") + 1) }' "$env_file")"
  state_of[$variant]="$state"
  if grep -Fxq 'stapled_app=true' "$state"; then
    submitted="$(awk -F= '$1 == "stapled_submitted_at" { print $2; exit }' "$state")"
    [[ "$submitted" =~ ^[0-9]+$ ]] || { echo "$variant: the stapled-app state records no submit time" >&2; exit 1; }
    deadline_of[$variant]=$((submitted + FALLBACK_SECONDS))
  else
    deadline_of[$variant]=""
  fi
  result_of[$variant]=pending
done
while :; do
  pending=false
  for variant in "${variants[@]}"; do
    [ "${result_of[$variant]}" = pending ] || continue
    # shellcheck disable=SC2086
    $POLL_TOOL "${state_of[$variant]}" --output "$REPORTS/$variant.log" > "$REPORTS/$variant.out" 2>&1
    status=$?
    cat "$REPORTS/$variant.out"
    deadline="${deadline_of[$variant]}"
    if [ "$status" -eq 0 ]; then
      result_of[$variant]=accepted
    elif [ -n "$deadline" ]; then
      # Queued, refused or not answered: only the deadline decides.
      if [ "$(now)" -ge "$deadline" ]; then
        result_of[$variant]=fallback
        echo "::warning::$variant: the DMG around the stapled app is not Accepted 6 h after its submission; its continuation ships the accepted first DMG"
      else
        pending=true
      fi
    elif [ "$status" -eq 2 ] || [ "$status" -eq 3 ]; then
      if [ $(( $(now) - start )) -ge "$OUTER_POLL_SECONDS" ]; then
        result_of[$variant]=stalled
        echo "::warning::$variant: the outer DMG is still In Progress; continue it with resume-nightly-notarization.yml"
      else
        pending=true
      fi
    else
      # Refused, or the query itself is broken: this variant fails; the
      # others are still decided.
      result_of[$variant]=failed
      echo "::error::$variant: the outer DMG submission failed or could not be queried"
    fi
  done
  [ "$pending" = true ] || break
  current="$(now)"
  if [ $((current - start)) -ge "$BUDGET_SECONDS" ]; then
    for variant in "${variants[@]}"; do
      deadline="${deadline_of[$variant]}"
      if [ "${result_of[$variant]}" = pending ] && [ -n "$deadline" ] && [ "$deadline" -le $((current + SLACK_SECONDS)) ]; then
        # Due within the slack: its continuation waits for the deadline.
        result_of[$variant]=fallback
        echo "::warning::$variant: the DMG around the stapled app is not Accepted and its 6 h deadline is $(date -u -d "@$deadline" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$deadline" +%Y-%m-%dT%H:%M:%SZ) (epoch $deadline); its continuation waits for it and ships the accepted first DMG"
      fi
    done
    echo "::warning::the polling budget ended before every outer DMG was decided; continue the rest with resume-nightly-notarization.yml"
    break
  fi
  # The next poll: one interval later, or the nearest deadline, or the end of
  # the budget, whichever comes first.
  wake=$((current + INTERVAL_SECONDS))
  for variant in "${variants[@]}"; do
    deadline="${deadline_of[$variant]}"
    if [ "${result_of[$variant]}" = pending ] && [ -n "$deadline" ] && [ "$deadline" -lt "$wake" ]; then
      wake="$deadline"
    fi
  done
  [ "$wake" -le $((start + BUDGET_SECONDS)) ] || wake=$((start + BUDGET_SECONDS))
  [ "$wake" -gt "$current" ] || wake=$((current + 1))
  sleep $((wake - current))
done
decided=()
for variant in "${variants[@]}"; do
  echo "$variant: ${result_of[$variant]}"
  case "${result_of[$variant]}" in accepted|fallback) decided+=("$variant") ;; esac
done
json="$(printf '%s\n' ${decided[@]+"${decided[@]}"} | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
if [ "${#decided[@]}" -gt 0 ]; then echo "decided=true" >> "$OUT"; else echo "decided=false" >> "$OUT"; fi
echo "outer_variants=$json" >> "$OUT"
for variant in "${variants[@]}"; do
  if [ "${result_of[$variant]}" = failed ]; then
    echo "At least one outer DMG failed or could not be queried; the decided variants above still continue." >&2
    exit 1
  fi
done
