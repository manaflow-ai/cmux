# Accepted decisions from Lawrence’s SQLite PR

[PR by Lawrence Chen](https://github.com/manaflow-ai/cmux/pull/12199), “Add bounded SQLite storage and Durable Object migration rules.” Inspected source at **a96093decaba279eba2f1124a7830282ba3a487c**. This is a design assessment of that revision, not a claim that its current deployment or full test suite was verified.

**Adoption status: accepted into the v2 design.** The patterns below are required; the scope/lifetime/retention differences in the next section remain intentional adaptations. [Implementation rules](IROH-DECISIONS.md#accepted-backend-implementation-rules).

| Decision in the PR | Accepted v2 requirement |
| --- | --- |
| Zod schemas validate decoded and encoded control frames and infer TypeScript types. | Author one contract and use it at both server boundaries. Keep our generated Swift/TS pipeline and explicit version compatibility. |
| LocalIrohBroker replaces the remote web broker behind the existing control core. | Keep transport/session coordination separate from operation and storage logic. Both HTTP and socket routes should use the same trusted implementation. |
| Drizzle durable-sqlite migrations run inside blockConcurrencyWhile during DO activation. | Finish bounded schema setup before serving requests; use Cloudflare’s supported storage transactions. |
| Shipped migrations are append-only, and the runbook separates worker rollback from database rollback. | Add compatible schema changes first; roll back code only if it understands the already-applied schema. Split large backfills from traffic cutover. |
| SQL triggers update usage totals and reject quota-breaking writes in the same transaction. | Enforce storage invariants centrally so another write path cannot skip them. For our team DO, attribute product usage to users and size shared physical guards separately. |
| Indexed expiry cleanup deletes at most 128 rows per pass; an empty store needs no permanent cleanup alarm. | Keep temporary state bounded. Our one-slot challenge needs no scheduled cleanup; issued credentials need no row per token. Apply bounded cleanup only if a separate retained-history policy requires it. |
| Miniflare/workerd tests exercise persisted restart, account isolation, real alarms and rollback behavior. | Test the actual DO runtime and storage behavior. Add team/user separation, hibernation, old-client and interrupted-renewal cases. |
| A boundary script detects Vercel, Hyperdrive and web-service dependencies. | Make architectural constraints executable and include the check in required build checks. Adapt the rule to allow our deliberate PlanetScale global ownership service. |
| Compact Axiom request/alarm events and Sentry exception hooks accompany Cloudflare logs. | Make backend behavior explainable, including every socket operation, rate-limit decision and response code. Keep telemetry bounded and independent of application success. |

Sources: [Zod schemas](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/src/controlPlaneSchemas.ts#L1), [local broker](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/src/iroh/localBroker.ts#L96), [activation](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/src/controlPlaneDo.ts#L89), [migration runbook](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/README.md#L220), [quota triggers](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/drizzle/20260910050000_usage_guards/migration.sql#L1), [cleanup](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/src/accountSqliteStorage.ts#L184), [runtime tests](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/e2e/account.test.mjs#L1).

## Required adaptations

- Apply the accepted [client replacement scope](IROH-DECISIONS.md#client-replacement-scope): remove incompatible legacy Mac/iOS behavior and supporting code. Preserve supported v2 contracts.
- The inspected control object is keyed by Stack **user**, not team. Our directory, state and permission boundary now use teams; request limits stay per user.
- Its 32 active bindings and 8 MiB logical storage quota were designed for one account. Do not impose those numbers on an entire team. Existing per-object platform limits still need protection.
- Its model retains a five-minute enrollment challenge and a 24-hour relay-token constant. We keep **30 minutes for both**. Its challenge creation inserts a new challenge ID; our design keeps one pending slot per identity.
- Its cleanup includes inactive bindings after 30 days. Do not silently remove durable device identity just because a Mac has been offline; review expiry separately for temporary records, revocation history and durable enrollment.
- Its control core still has scheduled work. Our challenge and credential design has no cleanup timer. Any future retention job needs a concrete data policy; application presence remains removed.
- The Zod frame checks are not a complete Swift generation/versioning system. Custom refinements, transforms and strict unknown-field rules need explicit compatibility treatment.
- The PR adds `boundary:check` and includes it in `bun run check`; the inspected workflow runs individual commands and does **not** invoke that boundary command. Our required workflow should call it explicitly. This is why a script’s existence alone does not prove continuous enforcement.
- Axiom currently covers DO HTTP fetch completion and alarms, plus selected operation failures. Every WebSocket method needs its own outcome/timing event for our requirements. Logging hooks do not prove the external services are configured in production.
- The Sentry helper catches delivery failures, but call sites await it and its fetch has no explicit timeout. Our version must bound delivery time and move it off the response path. Also sanitize exception text; truncation alone does not remove secrets.

Read the implementation rather than treating the PR description as proof that every migration guard, physical quota, logging promise or test is wired into the deployed path.

Dictionary: A migration changes a database schema. A backfill updates existing records. A trigger enforces a database rule automatically when data changes. A canary is a small initial rollout. Miniflare/workerd runs Cloudflare code in a local test runtime.
