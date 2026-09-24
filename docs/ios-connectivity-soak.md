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

## Verify path selection

The active `IrxConnection` subscribes to native Iroh path events and records
the initial selected path separately, because the event watcher does not replay
it. It refreshes the selected snapshot after a selection or a lag marker.
The diagnostic ring retains opened, closed, selected, and lagged edges even
when they use the same route class. Duplicate snapshots are collapsed per peer
and session, including interleaved connections, while their latest snapshot is
retained. Evicting that snapshot also expires its deduplication state. The
legacy connection stack uses the same vocabulary.

These records describe transport paths, including attempts that later fail app
admission. A path selection does not claim successful pairing or usable RPC.
Keeping that evidence helps diagnose connection failures before admission.

The mobile Axiom bridge emits one `ios_iroh_path_event` for each retained event.
Its bounded fields are `operation` (`opened`, `closed`, `selected`, `lagged`,
or `snapshot`), `path` (`relay`, `direct`, `private_network`, `loopback`, or
`unknown`), `transport` (`iroh`), `event_surface` (peer alias), and `event_c`
(the process-local session ID). It never sends an address, relay URL, endpoint
ID, or payload. `selected` means a native selection event; `snapshot` is an
observation of current state and must not be counted as another migration.
`private_network` includes LAN, private VPN, link-local, and loopback IPs; it
does not establish which physical network carried the packet.

The backend exports span `cmux.mobile.iroh.path`. Group by user, peer alias,
and session, and order by the client occurrence timestamp. Use the preview
dataset for a preview backend; the dataset name does not identify app channel.

```apl
['cmux-prod-otel-traces']
| where name == 'cmux.mobile.iroh.path'
| extend occurred = tostring(['attributes.custom']['cmux.mobile.occurred_at']),
    user = tostring(['attributes.custom']['cmux.user_id']),
    peer = tostring(['attributes.custom']['cmux.mobile.event_surface']),
    session = tostring(['attributes.custom']['cmux.mobile.event_c']),
    operation = tostring(['attributes.custom']['cmux.mobile.path_operation']),
    path = tostring(['attributes.custom']['cmux.mobile.path']),
    channel = tostring(['attributes.custom']['cmux.client.channel'])
| project occurred, user, peer, session, operation, path, channel
| sort by occurred asc
```

The opt-in native test below uses public Iroh relays, starts with relay-only
address information, then authorizes direct candidates. It checks the native
selection event, stable connection identity, and bidirectional data before and
after migration. Both peers run on one host, so this proves relay-to-local-IP
migration, not hole punching between two separate NATs or failback after an
interface disappears.

```sh
CMUX_IROH_PUBLIC_RELAY_TEST=1 swift test --package-path Packages/Shared/CmuxIrxTransport --filter IrxPathMigrationTests
```

Run the release gate in each mode when a path-selection change needs live
evidence:

```sh
scripts/run-iroh-release-gate.sh --mode automatic --tag <tag> --report-output /tmp/iroh-automatic.json
scripts/run-iroh-release-gate.sh --mode relay-only --tag <tag> --report-output /tmp/iroh-relay.json
scripts/run-iroh-release-gate.sh --mode direct-only --tag <tag> --report-output /tmp/iroh-direct.json
scripts/run-iroh-release-gate.sh --mode private-path --tag <tag> --report-output /tmp/iroh-private.json
```

Automatic mode should show Iroh opening a relay path and may later show a
selected direct or private-network path after admission. Relay-only should keep
the selected class at `relay`. Direct-only disables relay dialing and should
show a direct or private-network selected class. Private-path proves the
broker-authorized private route with relays disabled. A selected path is Iroh's
current choice; it is not a promise that every candidate was usable or that
the path remains fastest after a network change.

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
