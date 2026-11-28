# App compile (build fleet) is off the verdict unless the change is a Mac Release input

Above `jobs.app-compile-placement` and `jobs.app-compile-fleet` in `.github/workflows/cmux-next.yml`.

It runs on a pull request only when the change is a Mac Release input (`mac_release`), where it stands in
for the Mac Release compile (release-compile); app-compile-placement takes the same condition. Any other
pull request's app compile is off the verdict: in NOW's pr_verdict reading of 2026-11-25 15:27Z this Debug
compile was the last check on 3 of the newest 20 PR heads, at p50 20.8 min. Such a head is still checked:
its push's `Compiled:` trailer names a passing `cmux-next-swift-check --app --package CmuxNext`
(compile_trailer.py, an incremental compile of about 2.65 min for a one-file Swift change), and the tip
check's Release -Onone compile reports as cmux-next/compile (compile-status). The full compiles stay on the
`full-ci` label (release-compile) and on the feat-cmux-next push (release-compile-fast, release-compile).
Leo, 2026-11-25: "help 100x ci speed and the decrease of needed minutes aka lower resources and lower wall
time and lower machine time while maintaining a partial semblance of checks. and we can infrequenrly have
fuller checks."
