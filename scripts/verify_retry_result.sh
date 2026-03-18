#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 7 ]; then
  echo "usage: $0 <label> <attempt1-result> <attempt1-completed> <attempt1-passed> <attempt2-result> <attempt2-completed> <attempt2-passed>" >&2
  exit 2
fi

LABEL="$1"
ATTEMPT_1_RESULT="$2"
ATTEMPT_1_COMPLETED="$3"
ATTEMPT_1_PASSED="$4"
ATTEMPT_2_RESULT="$5"
ATTEMPT_2_COMPLETED="$6"
ATTEMPT_2_PASSED="$7"

if [ "$ATTEMPT_1_PASSED" = "true" ] || [ "$ATTEMPT_2_PASSED" = "true" ]; then
  echo "$LABEL passed."
  exit 0
fi

echo "$LABEL did not pass." >&2
echo "Attempt 1: result=${ATTEMPT_1_RESULT:-<unset>}, completed=${ATTEMPT_1_COMPLETED:-<unset>}, passed=${ATTEMPT_1_PASSED:-<unset>}" >&2
echo "Attempt 2: result=${ATTEMPT_2_RESULT:-<unset>}, completed=${ATTEMPT_2_COMPLETED:-<unset>}, passed=${ATTEMPT_2_PASSED:-<unset>}" >&2
exit 1
