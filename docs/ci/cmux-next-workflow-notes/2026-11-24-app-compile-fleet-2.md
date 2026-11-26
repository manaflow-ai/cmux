# 2026-11-24-app-compile-fleet-2

Above `reader=scripts/ci/fleet_compile_result.py` in the step `Compile-check the app at the pull request's head on the build fleet`'s script (job `app-compile-fleet`) in `.github/workflows/cmux-next.yml`.

The controller submits this head's Debug app compile when this job is queued (or when this read
names the pull request) and posts its result here; nothing waits on a runner of its own.
