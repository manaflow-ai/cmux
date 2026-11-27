# 2026-11-27-verify-final-dmg-nightly-1

Above `- name: Download final DMG (parallel ranges)` (job `verify-final-dmg-nightly`) in `.github/workflows/nightly.yml`.

A parallel-range read: one download-artifact stream took a p50 of 89 s
and up to 446 s here (run 41481821056, 7.4 of the job's 9 minutes). download-artifact takes over
when it fails.
