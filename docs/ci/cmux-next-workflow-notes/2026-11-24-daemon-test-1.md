# 2026-11-24-daemon-test-1

Above `if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]] && [[ "$(python3 -I -c 'import json, os; print...` in the step `Pack the exports for the base autofix`'s script (job `daemon-test`); Above `if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]] && [[ "$(python3 -I -c 'import json, os; print...` in the step `Pack the exports for the base autofix`'s script (job `generated-files`) in `.github/workflows/cmux-next.yml`.

A dispatch packs only as the base tier run (its base_tier input, read from the event so this
step needs no input the workflow may not declare).
