# IROH v2 implementation

Source: [accepted decisions](design/IROH-DECISIONS.md), revision 21, and the user's end-to-end implementation goal. Base: `72ce5e9b41a`, branch `feat-iroh-v2-generation`. Existing primary checkouts and unrelated branches are preserved.

## Required result

Implement the full backend, database, Mac/iOS clients, shared contracts, Dashboard integration, deployment environments, observability and accepted rate limits. Remove incompatible legacy client behavior. Production and staging use the new independent backend and fresh storage. Start with new IROH identity/cache namespaces and preserve existing user authentication.

**Lawrence's adopted decisions are implementation requirements.** Use Zod instead of Ajv for server input and output validation; export JSON Schema and generate Swift/TypeScript models with quicktype. HTTP and socket requests share one local operation handler. Apply immutable Drizzle migrations before serving requests, enforce storage bounds atomically in SQLite, handle storage failures explicitly, and run real workerd migration/persistence tests. Required release checks enforce the Cloudflare boundary and contract compatibility. Deploy in stages with complete, bounded observability. The [adopted rules](design/IROH-DECISIONS.md#accepted-backend-implementation-rules) and [source assessment](design/PR-12199-LESSONS.md) retain the full details and our adaptations, including no scheduled challenge cleanup.

Acceptance requires sustained real simulator use, including relay-only/high-latency traffic, credential rollover without session interruption, multiple workspaces and active Codex work using `gpt-5.3-codex-spark`, launch-to-workspace-list under 2.5 seconds, and resume within 2 seconds after 2 minutes backgrounded. Record one-hour runs against the deployed implementation, with environment, build, connection and timing evidence. The acceptance document supplies the complete matrix.

## Work and evidence

| Area | Status | Required evidence |
| --- | --- | --- |
| Fresh backend and team storage | Pending | Workerd integration tests, deployment receipts, real authenticated operations |
| Cross-team user quotas and ownership | Pending | Concurrency/isolation tests and real storage configuration |
| Versioned Zod contracts and generated Swift/TS | Foundation verified; integration pending | 35 named JSON schemas generate named Swift Codable/Sendable and TypeScript models; generation and TS compatibility checks pass. Swift compilation and client/server integration remain pending. |
| Mac/iOS integration and legacy removal | Pending | Source boundaries plus real startup, upgrade, failure and rollover paths |
| Authentication preservation and fresh IROH state | Pending | Upgrade run preserving sign-in while refusing old IROH trust/cache |
| Pairing opt-in | Pending | Off means no IROH activity, enabled flow works, disable cancels late callbacks |
| Dashboard | Pending | Team-filtered list/management and stable error behavior |
| Observability | Pending | HTTP/socket outcomes, limits, major events and telemetry delivery verified |
| Development/staging/production isolation | Pending | Distinct namespaces, keys, origins and seeded isolation probes |
| Real simulator acceptance | Pending | One-hour normal/relay-only runs, UI recordings, session counters and performance timings |
| Release checks and PR | Pending | Required checks, source-bound evidence and PR URL |

## Progress

- Initial goal turn: created a clean implementation worktree from fetched main and copied all accepted design documents into it. Previous discussion changed authoritative design state; runtime completion is unproven.
- The older `feat-iroh-v2` branch is a separate transport project and is not the implementation baseline.
- This worktree's current dogfood doctor passes for personal and agent authentication profiles. Several fleet Macs are reachable; a separate agent holds a general-purpose lease for focused Swift package validation.
- Backend foundations: Zod contracts, bounded HTTP/socket body handling, HMAC ticket signing/verification and device proof verification. Seven contract/crypto tests pass. Eight additional authentication/boundary tests pass, covering wrong scope/user, provider failures, bounded authentication work, oversized streaming bodies, retired-method backoff and invalid server output. These are local Bun tests, not deployed-backend evidence.
- Contract generation preserves separate operations instead of flattening the protocol into optional fields. Bidirectional TypeScript compatibility checks compare representable shapes; runtime array cardinality remains enforced by Zod and exported JSON Schema.
- Storage and shared native client work are active. Storage integration must use seconds for wire timestamps, collision-free tuple keys, replay protection that never evicts a still-valid proof, and bounded registration receipts. Real workerd verification is still required.
- Production/staging provisioning, native integration, full builds and sustained simulator acceptance have not yet run.
