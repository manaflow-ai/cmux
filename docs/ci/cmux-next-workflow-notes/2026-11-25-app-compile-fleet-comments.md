# cmux-next.yml app-compile-fleet: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `app-compile-fleet` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `- name: Check out the fleet compile reader`

Trusted base copy of the reader: the pull request's head never runs here.

## 2

Stood above: `reader=scripts/ci/fleet_compile_result.py`

The controller submits this head's Debug app compile when this job is queued (or when this read
names the pull request) and posts its result here; nothing waits on a runner of its own.

## 3

Stood above: `word="$(python3 "$reader" --sha "$REF" --repo "$GITHUB_REPOSITORY" --pr "$PR" --phase app-debug \`

The reader's reason line (stderr) names why a red failed (the build fleet job and its first error).

## 4

Stood above: `pending) verdict=unavailable; summary="The build fleet kept the compile of \`$REF\` queued past the wait, so nothing compiled this head here; the Release compile at land compiles it."`

pending: the controller holds this head's check but the fleet kept it queued or running past the wait. Like a
cmux-ci exit 75 (652 of 1030 red runs re-queued, 2026-11-23/24) it is a warning, and the
Release compile at land, plus the fallback where mac_release asks for it, still compile the head.
