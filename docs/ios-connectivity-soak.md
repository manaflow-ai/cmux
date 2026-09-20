# Recurring iOS connectivity checks

The basic workload runs the real iOS app for 600 seconds. Every ten seconds it
verifies an authenticated Iroh connection, RPC method inventory, terminal input
and returned output, workspace rename and restore, independent events,
notification reconciliation, chat session listing, and artifact scanning.
The connection identity must remain unchanged. A final terminal transaction
proves the connection is still usable at the end of the window.

The stress workload runs for 3,600 seconds, with a five-second target cadence.
Each cycle runs the basic transactions and the next step of a fixed four-step
sequence: workspace navigation and refresh; 128 lines of Unicode output;
create, open, use and close a scratch workspace; then refresh and use the
terminal again. Every 120th cycle replaces the fourth step with an explicit
disconnect and reconnect followed by another complete transaction set. The
disconnect preserves the saved pairing; retrying an already healthy session
alone does not establish reconnect coverage. Unexpected connection
replacement fails either workload. A cycle exceeding 30 seconds fails.

These are app-action and transport checks in an isolated Simulator. They do
not establish physical iPhone reliability, touch gesture correctness, cellular
handoff, suspended-app recovery, or pixel-perfect rendering. Screenshots are
supporting evidence; terminal output assertions determine liveness.

## Run

On a leased fleet Mac with matching tagged Mac and iOS Simulator builds:

```sh
scripts/run-iroh-release-gate.sh --mode relay-only --tag soki --skip-build --soak-profile basic --report-output /tmp/soki-result.json
scripts/run-iroh-release-gate.sh --mode relay-only --tag sokx --skip-build --soak-profile stress --report-output /tmp/sokx-result.json
```

Both builds use the agent auth profile and the same backend. Use distinct tags
for simultaneous workloads. Relay-only mode prevents same-host Simulator
loopback connectivity from bypassing the managed Iroh relay.

## Keep coverage current

Every PR touching mobile connectivity, authentication, lifecycle, workspace
actions, terminal input/output, or the mobile RPC contract must complete the
connectivity-soak item in the PR template. Update the action sequence and
assertions when behavior changes; explain unchanged coverage when no change is
needed. Run the affected workload against the PR revision before claiming it
is covered. Never replace a failed operation with an optional action or retry
that erases the original failure.

The app reports workload version, elapsed time, completed cycles, action counts,
maximum cycle duration, the last operation, compact per-operation latency
summaries containing count, total, minimum, maximum, and last duration, and
real UI timings from the simulator launch request to a rendered, connected workspace row,
and from the row's selection action to the first nonblank verified terminal frame.
The gate invokes the production row selection and back actions, waits for the
terminal view to unmount, then starts the full transport workload. Timings are
recorded once per process and survive SwiftUI reconstruction and later frames.
The two UI screenshots are captured from the isolated app window after each
measured boundary. Launch timing includes OS pre-main work, using the shared
Mach uptime clock. It does not measure physical touchscreen delivery latency. The monitor
merges those summaries into one bounded `latency-stats.json` file; it does not
retain one sample per cycle. The runner rejects missing
coverage (at least 50 basic or 300 stress cycles), old schemas, shortened
windows and non-Iroh routes. If the contract changes, bump `planVersion` and
update both validators in this repository and
`cmuxterm-hq/tools/ios-connectivity-monitor/monitor.py` together.

The supervisor runs from cmuxterm-hq. It records the installed source revision,
retains evidence, and queues every result until Slack acknowledges it. Refresh
both tagged builds together after merging an app change. A build older than
48 hours reports a stale-build failure rather than current app health.

The transport workload owns one terminal output consumer for the currently
probed surface. It drains and acknowledges idle output between commands rather
than reattaching and rehydrating up to 4,000 history rows for every marker.
Switching surfaces and explicit reconnects replace the consumer. Unexpected
ownership loss or stream termination still fails the run. The initial UI launch
and workspace-open measurements continue to use real rendered app surfaces.
