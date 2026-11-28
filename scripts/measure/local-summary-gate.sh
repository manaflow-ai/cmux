#!/usr/bin/env bash
# The local session-summary gate on this machine (a fleet Apple-silicon Mac, as a `cmux-ci run` step, or anywhere):
# the smallest installed local model against the 30 labeled sessions, beside the deterministic baseline.
# Args are local_summary_gate.py's (key=value too: runtime=ollama model=NAME strict=1). Report in $FAST_CHECKS_OUT.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
args=()
for a in "$@"; do
  case "$a" in
    runtime=*) args+=(--runtime "${a#runtime=}") ;;
    model=*) args+=(--model "${a#model=}") ;;
    strict=1) args+=(--strict) ;;
    *) args+=("$a") ;;
  esac
done
exec python3 "$here/local_summary_gate.py" "${args[@]+"${args[@]}"}"
