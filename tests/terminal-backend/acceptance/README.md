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

The command prints the manifest path. Launch the tagged app, identify the exact Swift, backend, and renderer PIDs, then bind each live identity. `--build-role` verifies the process executable against the corresponding packaged binary hash.

```bash
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role swift-host --build-role swift-host --pid <pid>
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role terminal-backend --build-role terminal-backend --pid <pid>
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role renderer-worker --build-role renderer-worker --pid <pid>
```

Place raw payloads and derived receipts under the manifest directory. A passing receipt cannot supply its own measurements. The verifier parses the primary payload again and requires exact equality with repository-derived metrics.

Structured payloads use this envelope:

```json
{
  "schema_version": 1,
  "artifact_kind": "process-census",
  "context": {},
  "records": [
    {"role": "swift-host", "pid": 101, "pty_master_fds": []},
    {"role": "terminal-backend", "pid": 202, "pty_master_fds": ["4:/dev/ptmx"]},
    {"role": "renderer-worker", "pid": 303, "pty_master_fds": []}
  ]
}
```

The repository tool can collect that payload directly from bound live processes. It verifies PID start identity and executable hash, then derives PTY ownership from `lsof` output.

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
  --pid 101 --pid 202 --pid 303 \
  --command-json '["./scripts/verify-terminal-backend-acceptance.py","collect-process-census"]' \
  --observation 'The Swift host owns no PTY master.'
```

Then attach the derived receipt to the check:

```bash
./scripts/verify-terminal-backend-acceptance.py record \
  --manifest <manifest> \
  --id PROC-1 \
  --status pass \
  --command-json '["./scripts/verify-terminal-backend-acceptance.py","collect-process-census"]' \
  --assertion 'The Swift host owns no PTY master.' \
  --artifact-json '{"kind":"process-census","path":"proc-1/process-census-receipt.json","pids":[101,202,303]}'
```

The structured derivers cover accessibility trees and queries, test results, frame provenance, input groups, latency samples, authority leases, linkage call sites, memory samples, negative cases, process censuses, protocol exchanges, PTY sizes, queue events, restart facts, runtime assertions, saturation events, canonical state values, structured frame logs, and compatibility matrices. Raw envelopes reject extra `metrics` keys.

Fidelity evidence uses a JSON corpus manifest. `golden-image` requires the named ASCII, ligatures, emoji, CJK, combining, wide-cell, style, cursor, palette, and OSC-color fixtures. `image-diff` names the embedded and external PNG for each case; the verifier fully decodes both images and derives geometry equality, changed pixels, maximum channel delta, and mean absolute error. Screenshot PNGs require valid CRCs, IDAT data that inflates to the declared dimensions, IEND, and no trailing bytes. Videos require a complete ISO BMFF video track, nonempty media data, coherent sample tables, positive duration, and a derived frame count.

Instruments `.trace` bundles are accepted only when `xcrun xctrace export --toc` parses them, reports a captured run, and names the required template. Caller-authored trace summaries are rejected.

The PROC-1 Allocations extractor reads `/trace-toc/run/data/table[@schema='os-signpost']` and accepts only `com.cmux.ghostty.process-census` events from the exact manifest-bound Swift-host PID. Ghostty increments process-lifetime atomics at the shared seam used by both `ghostty_surface_new` entrypoints and immediately around the real POSIX `openpty` allocation. Manual-I/O and embedded-PTY surface attempts have separate counters. `cmux terminal-backend-diagnostics --json` asks the Ghostty library to emit a schema-v1 interval whose unit events encode the monotonic snapshot; the diagnostics JSON is informational and is never an evidence source. Run that command after the measured workload and before stopping the Allocations trace. The verifier rejects missing or partial intervals, unknown events, overflow, decreasing snapshots, subtype disagreement, activity after the final snapshot, an unbound PID, and any source change that lets a constructor bypass instrumentation. It derives `swift_canonical_ghostty_allocations` and `swift_pty_master_allocations` from the exported signposts only.

The Time Profiler extractor reads `/trace-toc/run/data/table[@schema='time-profile']` and `/trace-toc/run/data/table[@schema='os-signpost']`. The `time-profile` table supplies process PID and symbolized `tagged-backtrace` rows. The extractor counts terminal shaping and render samples only for commit-bound Swift-host and renderer-worker PIDs. The `os-signpost` table supplies timestamp, main-thread identity, process PID, event type, interval identifier, name, and subsystem. It pairs exact `com.cmux.sidebar` intervals named `sidebar-selection-event-to-visible-state` and derives sample count, p50, p95, p99, and maximum duration. The endpoint is the selected row's SwiftUI render-input projection. Video remains the pixel-visible evidence.

The Metal System Trace extractor reads `/trace-toc/run/data/table[@schema='metal-application-encoders-list']`. It uses process PID, command-buffer label, and encoder label. Host blits require the exact pair `cmux host compositor: one IOSurface blit` and `cmux host compositor: no Ghostty rendering`. Renderer draws require the exact pair `cmux Ghostty worker semantic-scene render` and `Ghostty terminal glyph render pass`. Admitted frames come from the independently derived `frame-counters` payload. PROC-2 cross-artifact validation rejects more host blits than admitted frames.

PROC-1 combines two different time domains. The Allocations trace proves lifetime Ghostty runtime-app, canonical-surface, and PTY-allocation history through monotonic in-library counters, including objects freed before tracing began. The process census independently derives current PTY-master ownership from kernel-visible file descriptors. A passing run requires every Swift-host counter and current PTY ownership to be zero, and requires at least one PTY master in the terminal backend.

Final verification rejects missing required artifact kinds, failed P0 checks, reused role identities, unbound PIDs, changed hashes, a dirty worktree, or a manifest from a different commit.

```bash
./scripts/verify-terminal-backend-acceptance.py verify \
  --manifest <manifest> \
  --require-final-head \
  --require-all-p0
```
