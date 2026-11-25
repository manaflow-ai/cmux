# cmux-next.yml swift-canary-fleet: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `swift-canary-fleet` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `- name: Check out the fleet compile reader`

(scripts/ci/fleet_compile_result.py) and compile here only when it has none. Trusted base copy.

## 2

Stood above: `if [[ -n "${PR:-}" ]]; then`

A pull request reads its head's Debug app compile, which the controller submits when this job is
queued and posts back; no runner waits on it. Any non-pass leaves the Mac canary to run.

## 3

Stood above: `word=none`

A push reads the controller's tip check of this head (SwiftPM Release -Onone), which it compiles for
every feat-cmux-next push; this cmux-linux runner compiles nothing. Why: note-canary-linux-read.

## 4

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-35`

The PR app compile's gateway runner, judged at once (Leo, 2026-11-08: the Linux checks start at once

## 5

Stood above: `swift-canary-fleet:`

The build fleet's compile verdict for the Swift canary. Opt-in: with the
