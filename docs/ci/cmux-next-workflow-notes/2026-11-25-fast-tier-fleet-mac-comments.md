# cmux-next.yml fast-tier-fleet-mac: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `fast-tier-fleet-mac` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `exit 1`

finish exits already; the literal exit is the client guard's contract (no "$client" call follows).
shellcheck disable=SC2317

## 2

Stood above: `step_re='^cmux-ci: step ([0-9a-f]{6,64}) '`

A step id as the fleet tools read it (tip-test-compile.sh): 6 to 64 hex.

## 3

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-37`

The fast tier's queued hand-back, placed again (side_lane_placement.handback()). When fast-tier-fleet hands
