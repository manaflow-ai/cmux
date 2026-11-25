# cmux-next.yml generated-files: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `generated-files` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `- name: Log the Mac fallback`

The fleet's Linux job (generated-files-linux) decides this check; this Mac job is its fallback.

## 2

Stood above: `echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"`

An inherited socket would still name another home's daemon; empty is unset.

## 3

Stood above: `submodules: false`

The package graph reads no submodule; GhosttyNextKit comes from
SwiftPM (Packages/Shared/CmuxGhosttyKit).

## 4

Stood above: `submodules: false`

The package graph reads no submodule; GhosttyNextKit comes from
SwiftPM (Packages/Shared/CmuxGhosttyKit).

## 5

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-270`

A feat-cmux-next push or dispatch lists the pass artifacts with a cmux-bot token,

## 6

Stood above: `if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]] && [[ "$(python3 -I -c 'import json, os; print(str((json.load(open(os.environ["GITHUB_EVENT_PATH"])).get("inputs") or {}).get("base_tier", "")).lower())')" != true ]]; then`

A dispatch packs only as the base tier run (its base_tier input, read from the event so this
step needs no input the workflow may not declare).

## 7

Stood above: `out="$RUNNER_TEMP/generated/files"`

The regenerated files themselves, at their repository paths, so
they copy onto the PR head. A diff would be against the merge
commit, whose context the head may not have.

## 8

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-278`

Also after a failure or a cancel: end the daemon of this job's home and

## 9

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-279`

A pass records itself for the next run on the same inputs: an artifact named after

## 10

Stood above: `actions: read`

The reuse lookup lists artifacts.

## 11

Stood above: `- name: Keep Swift package builds on this owned Mac`

Checkout removes .build. Link the owned Mac's kept build after Xcode
