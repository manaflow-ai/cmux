# cmux-next.yml cmux-scheme-compile: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `cmux-scheme-compile` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `CMUX_SCHEME_FLEET_JOB: ${{ inputs.dev_daily != true && needs.cmux-scheme-compile-fleet.outputs.verdict == 'pass' && needs.cmux-scheme-compile-fleet.outputs.job_id || '' }}`

The fleet's Debug app for this head (pass only); empty: this Mac compiles it (docs/ci/cmux-next-workflow-notes.md#note-scheme-fleet).

## 2

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-74`

The DEV Release app is reused, not recompiled, when nothing it is built from changed

## 3

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-314`

R2 first (feat-cmux-next's bundles, published by the web-bundles job of

## 4

Stood above: `- name: Fetch the same-tree cmux-tui`

The Bundle cmux-tui phase bundles this commit's same-tree cmux-tui

## 5

Stood above: `- name: Source key of the web bundles`

The app's web bundles are build output (cx-vn5); the "Verify web

## 6

Stood above: `retention-days: 2`

As long as the product artifact it names.
