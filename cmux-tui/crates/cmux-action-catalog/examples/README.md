# Catalog daemon experiment

This default-off prototype tests the transport step in the private
`docs/design/hot-apply-more-kinds.md` design. It is an explicitly invoked example,
not part of the app or production daemon. It changes no caller or setting.

From `cmux-tui/`, on a fleet test worker (the working directory selects its pinned
Rust toolchain):

```sh
cargo run --locked --release -p cmux-action-catalog \
  --example catalog_rpc -- --experiment 500
```

The example starts its own child process, connects over a Unix socket in an
exclusive private directory, and serves `catalog.get` using the existing Rust
catalog. Its protocol is a four-byte big-endian byte length followed by JSON.
Only the parent's socket is used; no app, session, terminal, or user state is read
or changed. Requests and responses are capped, I/O and child startup/shutdown
have five-second deadlines, and dropping the experiment kills/reaps its own
child and removes its temporary directory.

The same harness compares the existing cached C ABI with the child daemon,
including JSON decode and disposal on both paths. It checks complete catalog
parity for English, Japanese, Portuguese and unknown-locale fallback, warms each
path, alternates measurement order, and prints p50/p99 nanoseconds and their
ratio. It also exercises invalid requests, oversized-frame failure cleanup, and
the timeout and cleanup of a peer that never completes its request frame.

The design's p99 bar is at most **1.2x**. A larger value is a useful negative
experiment result, not a transport failure; the receipt prints
`within_design_bar: false`. These are catalog retrieval numbers, not rendered
palette latency: the app currently reads its catalog once at launch, and the
production palette caller has not moved. Do not use this receipt alone to
justify migrating it. The existing `palette.rank` RPC is separate prior art.

Next step only after assessing the measurements: choose whether the production
daemon should own catalog retrieval and wire an opt-in app caller, then measure
that caller's user-visible p99 on a fleet Mac. No default changes in this slice.
