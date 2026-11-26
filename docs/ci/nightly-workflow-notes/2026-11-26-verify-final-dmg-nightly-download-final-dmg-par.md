# verify-final-dmg-nightly: Download final DMG (parallel ranges)

Where: the `verify-final-dmg-nightly` job in `.github/workflows/nightly.yml`, above `- name: Download final DMG (parallel ranges)`.

A parallel-range read: one download-artifact stream took a p50 of 89 s
and up to 446 s here (run 41481821056, 7.4 of the job's 9 minutes). download-artifact takes over
when it fails.
