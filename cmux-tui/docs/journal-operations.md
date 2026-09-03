# Journal and interaction operations

How to observe cmux-tui's runtime timing from the outside: the named budgets
every wait is bound by, and the interaction benchmark that measures how those
waits add up for a user or an agent.

## Named budgets

Every bounded wait in the daemon, the terminal hosts, and the clients is a
budget with one name, one value, and one interaction stage. `cmux_tui_core::budgets`
holds the values; the code sites that enforce them import those constants, so
there is one value per budget.

```bash
cmux diag budgets          # table
cmux diag budgets --json   # array of {name,value,unit,stage,purpose,site}
```

`stage` places a budget in the interaction lifecycle:

- `accept`: validating and applying a mutation to in-memory state.
- `durable`: the journal batch that carries the mutation has committed.
- `settle`: an external effect (host launch, terminate, first frame) reached its
  outcome.
- `frame`: a frontend paint cadence.
- `client`: a client-side wait on the daemon.
- `planned`: reserved by design, not enforced yet (for example
  `input.typeahead_bytes`, reserved for the launching-terminal typeahead queue).

A timeout error names the budget it exhausted, so an operator or an agent can
map a stall to one row of this table.

## Interaction bench

`cmux bench interact` drives a session as an ordinary client over the raw
control protocol and records the latencies a frontend or an agent actually
feels. It sends only existing commands; it is not a protocol command or a
resource operation.

```bash
# Throwaway session (started and stopped by the bench):
cmux bench interact --creates 20 --clients 1 --typing-probes 50
cmux --json bench interact --creates 20 --clients 8 --typing-probes 100

# Against a running session:
cmux --socket /path/to/session.sock bench interact --creates 20 --clients 4
```

Metrics, each reported as `count`, `p50`, `p90`, `p99`, `max` in milliseconds:

| metric | what it times |
| --- | --- |
| `create.response_ms` | create request write to the command response |
| `create.visible_ms` | create request write to the first tree delta on a separate `tree_events:"deltas"` subscriber that references the new surface (deltas may precede the response, so both are timed from the write) |
| `create.first_frame_ms` | `attach-surface` with `mode:"render"` to the first `render-state` |
| `close.surface_response_ms` | `close-surface` (view-only close) request to response |
| `close.terminal_response_ms` | `close-terminal` (process-terminating close) request to response; this is the one that waits on host exit escalation, bounded by `terminal.close_wait` |
| `typing.separate_conn_ms` | one-byte `send` on a connection that issues no creates, while creates are in flight |
| `typing.same_conn_interleaved_ms` | one-byte `send` on the connection that also issues creates, one probe submitted right after each create request; the distribution is what a keystroke waits when 1..K creates are queued ahead of it on the same connection |
| `typing.same_conn_after_batch_ms` | one-byte `send` on the create connection, all probes submitted after the whole create batch and before its responses are drained; every probe waits behind the entire batch, so p50 equals p99 and the value is the batch tail, not per-keystroke latency. A gap between either same-connection number and the separate-connection number is head-of-line blocking |

`--clients N` runs N concurrent create loops on N connections; `--creates K` is
creates per client; `--typing-probes M` sets the number of typing samples (the
interleaved probe is one per create and is enabled whenever M is non-zero). The
JSON output also carries `lifecycle_counts` (the `lifecycle` field on each
create response), `visibility_misses` (creates whose visibility delta did not
arrive within the grace window), `terminals_closed_at_teardown`,
`hosts_remaining` (terminal host processes still parented by the bench-owned
session owner after teardown; `null` where the platform cannot count them),
`warnings`, `errors`, `commit`, and `platform`. The text output prints the error
count and first error and the lifecycle counts above the table, and the table
carries `n` per metric.

The bench owns the session it runs against. At teardown it lists the terminal
catalog and closes every terminal that was not present before the run,
including the baseline typing target and creates that were only detached with
`close-surface`, because `server stop` keeps terminal hosts alive by design and
a view-only close leaves the terminal and its shell running. Run it only
against a throwaway session (the default) or a session nobody else is
mutating. It exits 1 when any create, close, or probe failed: percentiles over
a partial sample are not a measurement, and PTY exhaustion on a loaded machine
is the usual cause of that failure.

Read the numbers against the budget table: a `create.response_ms` far above the
`accept`-stage cost, or a `typing.same_conn_interleaved_ms` far above
`typing.separate_conn_ms`, is the interaction cost the zero-wait work removes. The record-only
`bench interact` job in `.github/workflows/cmux-tui.yml` publishes the JSON per
commit as the `cmux-tui-bench-interact-<os>` artifact. Design and targets:
`plans/cmux-tui-zero-wait-interaction.md` (IX0).
