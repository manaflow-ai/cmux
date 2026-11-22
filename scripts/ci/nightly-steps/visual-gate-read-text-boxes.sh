#!/usr/bin/env bash
# nightly.yml visual-gate-nightly: "Read the text boxes". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# Each state's boxes go to a temporary file that is moved into place
# only when ocr_boxes succeeded: a failed read leaves no text-boxes.json
# (the gate warns that overlap was not checked) and the next state is
# still read.
set -e  # the inline step ran under bash -e
set -uo pipefail
swiftc -O scripts/cmux-next/visual-gate/ocr_boxes.swift -o "$RUNNER_TEMP/ocr_boxes" || exit 0
for state in "$RUNNER_TEMP"/visual-gate/*/; do
  [ -f "$state/light.png" ] && [ -f "$state/dark.png" ] || continue
  if "$RUNNER_TEMP/ocr_boxes" "$state/light.png" "$state/dark.png" > "$state/text-boxes.json.part"; then
    mv "$state/text-boxes.json.part" "$state/text-boxes.json"
  else
    rm -f "$state/text-boxes.json.part"
    echo "::warning title=nightly-next visual gate::could not read the text boxes of $(basename "$state")"
  fi
done
