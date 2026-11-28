# 2026-11-25-fleet-compile-down

Above `down) ...` in the `case "$word"` of swift-canary-fleet and release-compile-fast in `.github/workflows/cmux-next.yml`.

`down` from scripts/ci/fleet_compile_result.py: the build controller, which serves the tip check's results, was reached and gave no answer for 60 s (the CDN's 524 or the read's own timeout). A compile submits to that same process, so the job gives no verdict at once instead of submitting. 2026-11-23 from 09:30Z the controller answered a plain read in 78 s: 48 of 52 app compile jobs from 10:00 to 10:50Z spent 6.4-7.5 min reading and 5-8.5 min more in `cmux-ci compile-check` (exit 69 or 75), with no verdict at the end.
