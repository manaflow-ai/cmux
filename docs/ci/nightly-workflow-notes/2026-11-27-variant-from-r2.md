# The variant artifact from R2, off the signing Mac (2026-11-27)

nightly-next-one's "Upload nightly variant artifacts" ran on the signing Mac after the feed write and uploaded
cmux-nightly-variant-arm64: the immutable DMG plus the appcasts and this build's deltas. In green run 46065369073
it moved 237 MB in 84 s (about 2.8 MB/s, network-bound), and it ran even when a newer push waited
(newer-push-waiting.sh skips only the size budget and the deltas). The next build waited on that Mac for it.

The same DMG is already on R2 before the feed is written: nightly-next-one uploads
`<prefix>-arm64-<build>.dmg` to the nightly-next bucket and reads it back by SHA-256 (30.8 s in that run).

Now, once the feed is written (`feed_written`), the Mac uploads only the feed files (no `*.dmg`) as
cmux-nightly-feed-files-arm64, KB to a few MB. A Linux job, nightly-next-variant-from-r2, downloads the DMG from
R2, requires its SHA-256 to be one of cmux-nightly-tested-arm64's digests (the DMG the tests ran on), adds the
feed files, and uploads cmux-nightly-variant-arm64 with compression-level 0 (a DMG does not compress). The
artifact's name and files are the same as before, so its readers (nightly-next-deltas, published-build's
readers: publish-nightly-next-github, build-nightly-deltas, nightly-next-pkg, and recovery) are unchanged;
nightly-next-deltas and published-build now also need the new job.

When no feed was written (a refused or failed publish) the Mac uploads the whole variant artifact as before, so
recovery still finds the DMG.

Expected: the signing Mac is free about 80 s sooner per published build (84 s upload -> a few seconds). The
artifact's readers see it about a minute later, off the feed's critical path.
