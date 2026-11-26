# 2026-11-26-mac-jobs-after-merge

Above the `if:` of the job `swift-test` in `.github/workflows/cmux-next.yml` (beside note-46). The jobs
`daemon-test`, `release-compile` and `cmux-scheme-compile` read the base the same way.

Since 2026-11-26 full-ci (the land tier's handoff label, so about one PR head in ten) no longer buys swift test on
a pull request into feat-cmux-next, nor the Mac Release compile, the app scheme compile (Debug) or the Mac
daemon tests (their `if:` reads the base). Catch data, 641 sampled merges over 30 days (cmuxterm-hq
docs/findings/2026-11-25-ci-value.md): none of the four had a real catch, a red that a later code change on the
same pull request turned green. swift test was red on 16 of 518 heads: 10 merged red, 6 never re-run. Release
compile (Xcode 26) was red on 2 and daemon tests on 9; none was a real catch. In the 10 hours to 2026-11-25T23Z they
held 11.3k Mac minutes on pull requests. After merge: the tip suite dispatch above (swift test), the push run of
feat-cmux-next and the nightly (Release, scheme, daemon), base-red watch naming the culprit. A pull request keeps
its compile verdict from the build fleet (app compile, the Swift canary step) and, when the fleet gives none, the
Mac Release compile fallback.
