# Terminal backend acceptance evidence

`spec.json` defines the P0 runtime contract. `manifest.schema.json` defines the evidence record. `scripts/verify-terminal-backend-acceptance.py` creates and validates commit-bound evidence outside the source worktree.

Capture starts only from a clean final commit and a tagged app built from that same clean commit. The tagged app embeds `CMUXSourceCommit` and `CMUXSourceDirty`; the manifest hashes its Info.plist, Swift host, terminal backend, and renderer worker. Any source, submodule, app metadata, executable, or artifact mutation invalidates verification.

Use four named roles. The acceptance author, implementer, interaction profiler, and final artifact verifier must all differ.

```bash
./scripts/verify-terminal-backend-acceptance.py capture \
  --tag ctuibk \
  --artifact-root /tmp/cmux-terminal-backend-evidence \
  --protocol-min 8 \
  --protocol-max 9 \
  --acceptance-author acceptance-author \
  --implementer implementer \
  --interaction-profiler interaction-profiler \
  --artifact-verifier artifact-verifier
```

The command prints the manifest path. Launch the tagged app, identify the exact Swift, backend, and renderer PIDs, then bind each live identity. `--build-role` verifies the process executable against the corresponding packaged binary hash. PROC-1 also binds every direct terminal child as `terminal-shell`, without a build role, so its start identity and executable hash become part of the manifest.

```bash
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role swift-host --build-role swift-host --pid <pid>
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role terminal-backend --build-role terminal-backend --pid <pid>
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role renderer-worker --build-role renderer-worker --pid <pid>
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role terminal-shell --pid <shell-pid>
```

Discover shell PIDs from the manifest-bound backend socket, not from a global process-name search. Read the PTY terminal handles from `list-workspaces`, then query each handle with `process-info` and bind every non-null PID. The packaged backend executable is the CLI client, and the already-running manifest-bound backend remains the server.

```bash
<tagged-app>/Contents/Resources/bin/cmux-terminal-backend \
  --socket <manifest-backend-socket> --json list-workspaces
<tagged-app>/Contents/Resources/bin/cmux-terminal-backend \
  --socket <manifest-backend-socket> --json process-info --surface <surface-handle>
```

Place raw payloads and derived receipts under the manifest directory. A passing receipt cannot supply its own measurements. The verifier parses the primary payload again and requires exact equality with repository-derived metrics.

PROC-1 audits the actual tagged app before inspecting live processes. The collector attests the fixed `cmux-backend-only` native target in `cmux.xcodeproj`, its Frameworks phase, the `CmuxTerminalFrontend` SwiftPM closure, a copied and hash-bound link map, and every in-bundle Mach-O load. It rejects Ghostty and PTY symbols, legacy runtime identities, and dynamic-load escape hatches, and requires `CMUXTerminalRuntimeOwnership=backend-only`. Receipt derivation and final verification rerun that audit against the manifest-bound app and copied link map.

```bash
./scripts/verify-terminal-backend-acceptance.py collect-host-backend-only-attestation \
  --manifest <manifest> \
  --link-map <tagged-build-LinkMap.txt> \
  --output proc-1/host-backend-only-attestation-raw.json
./scripts/verify-terminal-backend-acceptance.py derive-receipt \
  --manifest <manifest> \
  --id PROC-1 \
  --kind host-backend-only-attestation \
  --status pass \
  --primary proc-1/host-backend-only-attestation-raw.json \
  --output proc-1/host-backend-only-attestation-receipt.json \
  --pid 101 \
  --command-json '["./scripts/verify-terminal-backend-acceptance.py","collect-host-backend-only-attestation"]' \
  --observation 'The production Swift host load closure is backend-only.'
```

PROC-1 process censuses use the `proc-1-process-census-v2` semantic schema inside the common version-1 raw envelope. The collector records two identical `identify` samples around the workspace and `process-info` queries. Each host/backend/renderer row contains PID, start time, executable hash, and kernel-visible PTY masters. Each shell row additionally binds its terminal ID, workspace ID, backend-reported TTY, kernel controlling TTY, parent PID, TTY `dev_t`, and open slave descriptors.

```json
{
  "schema_version": 1,
  "artifact_kind": "process-census",
  "context": {
    "semantic_schema": "proc-1-process-census-v2",
    "backend_socket": "/tmp/cmux-tui-501/example.sock",
    "captured_at_before": "2026-07-18T12:00:00Z",
    "captured_at_after": "2026-07-18T12:00:01Z",
    "identity_before": {
      "pid": 202,
      "protocol": 9,
      "session_id": "11111111-1111-4111-8111-111111111111",
      "daemon_instance_id": "22222222-2222-4222-8222-222222222222",
      "topology_revision": 7,
      "canonical_topology_revision": 5
    },
    "identity_after": {
      "pid": 202,
      "protocol": 9,
      "session_id": "11111111-1111-4111-8111-111111111111",
      "daemon_instance_id": "22222222-2222-4222-8222-222222222222",
      "topology_revision": 7,
      "canonical_topology_revision": 5
    },
    "terminal_inventory": [{
      "surface_handle": 41,
      "terminal_id": "33333333-3333-4333-8333-333333333333",
      "workspace_id": "44444444-4444-4444-8444-444444444444",
      "dead": false,
      "runtime": "local"
    }]
  },
  "records": [
    {"role": "swift-host", "pid": 101, "started_at": "2026-07-18T11:59:00Z", "executable_sha256": "<sha256>", "pty_masters": []},
    {"role": "terminal-backend", "pid": 202, "started_at": "2026-07-18T11:59:00Z", "executable_sha256": "<sha256>", "pty_masters": [{"fd": "4u", "name": "/dev/ptmx", "raw_device": "0xf00002a"}]},
    {"role": "renderer-worker", "pid": 303, "started_at": "2026-07-18T11:59:00Z", "executable_sha256": "<sha256>", "pty_masters": []},
    {"role": "terminal-shell", "pid": 404, "started_at": "2026-07-18T11:59:00Z", "executable_sha256": "<sha256>", "parent_pid": 202, "surface_handle": 41, "terminal_id": "33333333-3333-4333-8333-333333333333", "workspace_id": "44444444-4444-4444-8444-444444444444", "protocol_tty": "/dev/ttys042", "kernel_controlling_tty": "/dev/ttys042", "kernel_tty_raw_device": "0x1000002a", "tty_fds": [{"fd": "0u", "name": "/dev/ttys042", "raw_device": "0x1000002a"}]}
  ]
}
```

The repository tool collects this payload from bound live processes. It invokes `identify`, `list-workspaces`, and `process-info` through the manifest's exact backend socket, rejects a backend PID/session/daemon/topology change during collection, verifies every PID/start/hash twice, derives parent and controlling-TTY facts from `ps`, and derives file-descriptor device identities from `lsof -F ftnr`. Every live local terminal in the tree must have one shell row. External parser-only terminals have an inventory row with `runtime: external` and no shell or PTY relation.

```bash
./scripts/verify-terminal-backend-acceptance.py collect-process-census \
  --manifest <manifest> \
  --output proc-1/process-census-raw.json
```

Create the receipt through the repository deriver. It decodes the raw payload, calculates the metrics, checks the pass invariants, and hashes every attachment.

```bash
./scripts/verify-terminal-backend-acceptance.py derive-receipt \
  --manifest <manifest> \
  --id PROC-1 \
  --kind process-census \
  --status pass \
  --primary proc-1/process-census-raw.json \
  --output proc-1/process-census-receipt.json \
  --pid 101 --pid 202 --pid 303 --pid 404 \
  --command-json '["./scripts/verify-terminal-backend-acceptance.py","collect-process-census"]' \
  --observation 'Every live terminal child and PTY master has one manifest-bound kernel relation.'
```

Then attach the derived receipt to the check:

```bash
./scripts/verify-terminal-backend-acceptance.py record \
  --manifest <manifest> \
  --id PROC-1 \
  --status pass \
  --command-json '["./scripts/verify-terminal-backend-acceptance.py","collect-host-backend-only-attestation"]' \
  --command-json '["./scripts/verify-terminal-backend-acceptance.py","collect-process-census"]' \
  --assertion 'The production host is linked only to the backend frontend closure.' \
  --assertion 'Every local terminal ID and workspace ID maps to one manifest-bound direct cmuxd child and one kernel PTY relation.' \
  --artifact-json '{"kind":"host-backend-only-attestation","path":"proc-1/host-backend-only-attestation-receipt.json","pids":[101]}' \
  --artifact-json '{"kind":"process-census","path":"proc-1/process-census-receipt.json","pids":[101,202,303,404]}'
```

The structured derivers cover accessibility trees and queries, test results, frame provenance, input groups, latency samples, authority leases, linkage call sites, memory samples, negative cases, process censuses, protocol exchanges, PTY sizes, queue events, restart facts, runtime assertions, saturation events, canonical state values, structured frame logs, and compatibility matrices. Raw envelopes reject extra `metrics` keys.

Linkage evidence is generated by the verifier, not written by the collector. The command below reads fixed Swift-host, terminal-package, renderer-worker, and browser roots directly from the manifest's Git commit. Receipt derivation and final verification repeat that scan and require the raw payload to match it exactly, including the commit, rule hash, source-tree hashes, category records, and findings. Empty or edited records fail.

```bash
./scripts/verify-terminal-backend-acceptance.py collect-linkage-audit \
  --manifest <manifest> \
  --output state-2/linkage-audit-raw.json
```

Fidelity evidence uses a JSON corpus manifest. `golden-image` requires the named ASCII, ligatures, emoji, CJK, combining, wide-cell, style, cursor, palette, and OSC-color fixtures. `image-diff` names the embedded and external PNG for each case; the verifier fully decodes both images and derives geometry equality, changed pixels, maximum channel delta, and mean absolute error. Screenshot PNGs require valid CRCs, IDAT data that inflates to the declared dimensions, IEND, and no trailing bytes. Videos require a complete ISO BMFF video track, nonempty media data, coherent sample tables, positive duration, and a derived frame count.

Instruments `.trace` bundles are accepted only when `xcrun xctrace export --toc` parses them, reports a captured run, and names the required template. Caller-authored trace summaries are rejected.

The Time Profiler extractor reads `/trace-toc/run/data/table[@schema='time-profile']` and `/trace-toc/run/data/table[@schema='os-signpost']`. The `time-profile` table supplies process PID and symbolized `tagged-backtrace` rows. The extractor counts terminal shaping and render samples only for commit-bound Swift-host and renderer-worker PIDs. The `os-signpost` table supplies timestamp, main-thread identity, process PID, event type, interval identifier, name, and subsystem. It pairs exact `com.cmux.sidebar` intervals named `sidebar-selection-event-to-visible-state` and derives sample count, p50, p95, p99, and maximum duration. The endpoint is the selected row's SwiftUI render-input projection. Video remains the pixel-visible evidence.

The Metal System Trace extractor reads `/trace-toc/run/data/table[@schema='metal-application-encoders-list']`. It uses process PID, command-buffer label, and encoder label. Host blits require the exact pair `cmux host compositor: one IOSurface blit` and `cmux host compositor: no Ghostty rendering`. Every other encoder submitted by the bound Swift PID must match a source-reviewed nonterminal pair in the verifier. Renderer workers may submit only the exact pair `cmux Ghostty worker semantic-scene render` and `Ghostty terminal glyph render pass`; cmuxd may submit none. Unknown, empty, or differently labeled encoder pairs fail instead of disappearing from the counts. Admitted frames come from the independently derived `frame-counters` payload. PROC-2 cross-artifact validation rejects more host blits than admitted frames.

PROC-1 combines a build-time host audit with a live protocol-and-kernel census. The host audit prevents dormant or dynamically loaded Ghostty and PTY code from hiding behind a runtime feature flag. The census requires zero PTY masters in Swift and renderer workers. For each live local terminal, the exact cmuxd socket reports the terminal ID, workspace ID, child PID, and slave TTY; the OS independently reports that PID as a direct cmuxd child with the same controlling TTY and open slave FD; and cmuxd has exactly one `/dev/ptmx` FD whose Darwin `dev_t` minor matches that slave. Duplicate shell PIDs, duplicate TTY minors, duplicate master minors, dead terminals, extra masters, missing shell bindings, and topology churn fail.

macOS does not expose a public same-UID API that applies `TIOCPTYGNAME` to another process's master FD. The census therefore composes three independently checked facts: cmuxd's `MasterPty::tty_name` returned by `process-info`, the shell's kernel controlling TTY and slave FD, and the master/slave `dev_t` minor relation reported by `lsof`. This proves ownership without debugger privileges, but it is not a single cross-process kernel ioctl attestation.

LIFE-1 accepts a restart transcript only from a hashed, commit-bound external collector whose PID and start identity are manifest-bound. The transcript has chronological `before`, `host-absent`, and `after` phases. The middle phase must contain no Swift PID while the exact cmuxd, daemon instance, shell PID/start/TTY, session, terminal epoch, cwd, topology digest, reader UUID, and scrollback sentinel remain unchanged and the reader sequence and unread count advance. The final phase must use a different Swift PID with the same packaged executable hash. Every process identity in all three phases is cross-checked against the manifest.

Final verification rejects missing required artifact kinds, failed P0 checks, reused role identities, unbound PIDs, changed hashes, a dirty worktree, or a manifest from a different commit.

```bash
./scripts/verify-terminal-backend-acceptance.py verify \
  --manifest <manifest> \
  --require-final-head \
  --require-all-p0
```
