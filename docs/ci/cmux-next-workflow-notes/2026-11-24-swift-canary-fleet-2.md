# 2026-11-24-swift-canary-fleet-2

Above `if [[ -n "${PR:-}" ]]; then` in the step `Compile-check CmuxNext on the build fleet`'s script (job `swift-canary-fleet`) in `.github/workflows/cmux-next.yml`.

A pull request reads its head's Debug app compile, which the controller submits when this job is
queued and posts back; no runner waits on it. Any non-pass leaves the Mac canary to run.
