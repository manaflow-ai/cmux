#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Decide the fleet build's REF capture".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
# Why: note-485
echo "started=$(date +%s)" >> "$GITHUB_OUTPUT"
if [[ "$CMUX_NEXT_RUNNER" != glaeda-* ]]; then echo "capture=false" >> "$GITHUB_OUTPUT"; exit 0; fi
key="$(python3 -I scripts/cmux-next/hybrid_ref_capture.py key .)"
# Why: note-405
if have="$(python3 -I scripts/cmux-next/hybrid_ref_capture.py have --key "$key" --repo "$GITHUB_REPOSITORY" --budget 600)"; then
  complete="$(sed -n 's/^complete=//p' <<< "$have")" incomplete="$(sed -n 's/^recent_incomplete=//p' <<< "$have")"
  capture=false compile=false
  [[ "$complete" == 0 ]] && capture=true
  [[ "$capture" == true && "$incomplete" == 0 ]] && compile=true
  echo "REF key $key: readable complete captures $complete, incomplete today $incomplete, capture $capture, compile $compile"
  printf 'key=%s\ncapture=%s\ncompile=%s\n' "$key" "$capture" "$compile" >> "$GITHUB_OUTPUT"
  exit 0
fi
# Why: note-486
printf 'key=%s\ncapture=true\ncompile=true\n' "$key" >> "$GITHUB_OUTPUT"
echo "::error title=REF capture lookup failed::the capture artifact lookup for REF key $key failed (log above); compiling and capturing anyway"
exit 1
