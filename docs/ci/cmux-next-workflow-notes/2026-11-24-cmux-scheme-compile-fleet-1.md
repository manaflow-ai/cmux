# 2026-11-24-cmux-scheme-compile-fleet-1

Above the step `Read the build fleet's app build` (job `cmux-scheme-compile-fleet`) in `.github/workflows/cmux-next.yml`.

The controller builds this head's whole Debug app when it sees this job queued (or this
read names the head) and serves the result; this job holds no Mac and never fails: a red or missing verdict
sends the Mac job to compile, as before.
