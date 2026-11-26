# 2026-11-24-dev-daily-place-1

Above `cmux-scheme-compile-fleet:` in `.github/workflows/cmux-next.yml`.

The cmux app scheme's Debug app, built by the build fleet's app recipe instead of xcodebuild on a Mac; the
Mac job below takes it and only runs what needs a Mac (the crash gate), or compiles as the logged fallback.
