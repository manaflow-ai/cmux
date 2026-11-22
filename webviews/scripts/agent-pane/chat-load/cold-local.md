# Process-cold local first page

`cold_local.py` writes a deterministic chat with 10,000 completed turns, 8 KiB
assistant messages and 8 MiB event segments. It starts a **new daemon process**
for each sample, initializes it, opens the one chat once, and shuts it down.
The command list lives in session metadata, matching current acpmux. There are
no tools or noisy harness records in this fixture.

From the repository root, on the fleet:

```sh
cmux-ci test --setup rust --timeout 3600 --artifact /tmp/cold-local-results -- bash -c '
  set -eu
  : "${CARGO_TARGET_DIR:?fleet warm Cargo target required}"
  (cd cmux-tui && cargo build --release --locked -p acpmux --bin acpmux)
  python3 -I webviews/scripts/agent-pane/chat-load/cold_local.py \
    "$CARGO_TARGET_DIR/release/acpmux" "$FAST_CHECKS_OUT" --runs 3
'
```

`cold-local.json` records the source head, binary digest, exact fixture byte and
record counts, and every sample. `ready_ms` and `initialized_ms` start at daemon
spawn. Each RPC's send/receive timestamps start at chat open. `first_page_ms`
ends when attach returns, and `draw_ready_ms` includes the older-daemon opener
fallback when needed. Both exclude the background command-list read and detach.
The sample fails if the returned first page lacks the newest message marker.

This is process-cold, **not OS-cache-cold**: fixture creation warms disk caches,
and later samples can reuse OS pages. It measures the daemon data path, not a
browser frame or native click. Internal attach work (first sequence, superseded
turns, opener lookup) is combined in the attach stage. Use browser and native
frame harnesses separately to assess the 300 ms final-frame budget.

Run the behavioral checks on the fleet with:

```sh
cmux-ci test --setup none -- python3 -m unittest discover \
  -s webviews/scripts/agent-pane/chat-load -p 'test_*.py'
```

`DAEMON_BENCH_SOURCE` selects an older `daemon_bench.py` for red/green protocol
checks, without replacing the current harness or changing product code.
