# 2026-11-27-resolve-nightly-cmux-tui-client-1

Above `continue-on-error: true` (job `resolve-nightly-cmux-tui-client`) in `.github/workflows/nightly.yml`.

A reused checkout whose store makes git's pack-objects BUG() out (signal 6) fails every retry in place;
the next two steps drop that store and check out fresh. Leo, 2026-11-25: "are we able to decouple".
