# resolve-nightly-cmux-tui-client: continue-on-error: true

Where: the `resolve-nightly-cmux-tui-client` job in `.github/workflows/nightly.yml`, above `continue-on-error: true`.

A reused checkout whose store makes git's pack-objects BUG() out (signal 6) fails every retry in place;
the next two steps drop that store and check out fresh. Leo, 2026-11-25: "are we able to decouple".
