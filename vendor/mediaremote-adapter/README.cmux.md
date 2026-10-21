# mediaremote-adapter (vendored)

Source: https://github.com/ungive/mediaremote-adapter at
`0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd` (2026-10-17), BSD-3-Clause (`LICENSE`).

The Now Playing card reads what other apps play (Spotify, Music) through it.
Since macOS 15.4 only Apple-signed processes may read MediaRemote, so
`/usr/bin/perl` runs `bin/mediaremote-adapter.pl`, which loads
`MediaRemoteAdapter.framework` and prints Now Playing as JSON lines.

Kept: `LICENSE`, `bin/`, `include/`, `src/adapter`, `src/private`,
`src/utility`, and `src/test/NowPlayingTest.h` (`src/adapter/test.m` imports
it). Left out: the CMake and Make files, the test client
(`src/test/main.m`, `src/test/NowPlayingTest.m`), editor settings and
scripts. No file is changed.

`scripts/cmux-next/bundle-mediaremote-adapter.sh` (Xcode phase "Bundle
MediaRemote adapter") compiles it the way the upstream `CMakeLists.txt` does
and puts the framework in `Contents/Frameworks` and the script in
`Contents/Resources/MediaRemoteAdapter`. Swift side:
`Packages/macOS/CmuxNext/Sources/CmuxNextNowPlaying/MediaRemoteAdapter.swift`.

To update: copy the same paths from a newer upstream commit, update the commit
above, and check that `stream --micros` still prints the keys
`SystemNowPlayingFeed` reads.
