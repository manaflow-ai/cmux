# 2026-11-24-swift-canary-fleet-3

Above `word=none` in the step `Compile-check CmuxNext on the build fleet`'s script (job `swift-canary-fleet`) in `.github/workflows/cmux-next.yml`.

A push reads the controller's tip check of this head (SwiftPM Release -Onone), which it compiles for
every feat-cmux-next push; this cmux-linux runner compiles nothing. Why: note-canary-linux-read.
