# build-sign-notarize-nightly: submodules: false

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `submodules: false`.

Main and RC signing do not need submodules. nightly-next's notice
check reads ghostty-next/build.zig.zon, so initialize that optional
submodule in the next step only for the cmux-next track.
