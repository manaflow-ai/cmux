# Chat-size measurement validity

Owner notice: the manual `god_daemon::chat_size_sweep` harness and its
`scripts/measure/chat-size-sweep.sh` entry point now compare generated histories
at 1 MB, 100 MB, 1 GB and 4 GB. This changes measurement tooling, not the daemon's
product behavior. `scripts/bench/cmux-bench chat-size` registers the same harness
for ledger imports and comparisons.

A cursor advanced by a fixed number of raw sequences can exhaust a small
baseline while still reading full pages from a large history. That makes the
baseline artificially fast, or produces future-cursor errors. Paging samples
now repeat fixed positions at 90%, 50% and 5% of each history; they are warm-page
measurements. Returned record counts accompany the latency distributions, and
empty pages fail the sweep rather than count as fast samples.

Incomplete evidence must not become a successful ratio: skipped sizes, failed
log loads, page errors and missing measurements fail the harness. Detectors are
`incomplete_chat_sizes_cannot_be_reported_as_success`,
`chat_size_ratios_use_the_same_metric_and_baseline`, the live sweep's nonempty
page check, and `scripts/bench/tests/test_chat_size.py` at the ledger boundary.
The import rejects missing completion markers and mismatched source commits
before writing any rows.

Every prompt, page read and shutdown has a deadline. The hermetic test process
explicitly keeps `FAST_CHECKS_OUT` so its bounded daemon-log tails survive scratch
cleanup. Generated chat content is never included in the evidence artifacts.

Run on the Linux fleet at a pushed PR head:

```sh
cmux-ci test --route fleet --timeout 7200 --artifact /tmp/chat-size-results -- bash scripts/measure/chat-size-sweep.sh 1M,100M,1G,4G
```

The daemon table does not establish app rendering, scroll-frame or keystroke
latency. Those require a separate measurement of the published app.

Fixture generation uses the same 20 KiB record cap at every size. Before the
measured daemon starts, `tests/support/chat_size_seed.rs` finishes only unresolved
queue/direct prompts, inbox items and the final interrupted turn from the pinned
generator. It preserves the generated prefix and creates no journal, kind index
or restore point. Completion counts and actual log bytes accompany each result.
Unsupported lifecycle state fails preparation; the live attach must then report
idle, no queued prompts and no active turn. This prevents recovered work from
being misattributed to history size. The helper's idempotence/prefix tests and
`initialStateError` rejection are the detectors.

Each timed page also reports original-history record counts. It fails when fixture
completion records are the majority, so an idle seed cannot pass by replacing the
newest transcript with preparation bookkeeping. `historyEndSeq` distinguishes the
original generated prefix from the completion suffix.
