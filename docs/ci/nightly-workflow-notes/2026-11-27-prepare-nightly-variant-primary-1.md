# 2026-11-27-prepare-nightly-variant-primary-1

Above `submodules: false` (job `prepare-nightly-variant-primary`) in `.github/workflows/nightly.yml`.

Main and RC signing do not need submodules. nightly-next's notice
check reads ghostty-next/build.zig.zon, so initialize that optional
submodule in the next step only for the cmux-next track.
