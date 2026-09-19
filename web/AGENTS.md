<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## Complexity ratchet

Keep ESLint as the full Next.js lint. Oxlint adds one incremental gate for
cyclomatic complexity, configured in `.oxlintrc.json` with the classic variant
and a maximum of 20. Run `bun run lint:complexity` from `web/` before handoff.
The gate rejects changes to that limit or variant, and fails when a baseline
entry becomes stale. The baseline file is mandatory, so deleting it also fails
the gate.

The gate scans all production JavaScript and TypeScript and compares the
findings with `oxlint-complexity-baseline.txt`. The baseline contains only the
legacy findings present when this gate was introduced. Any new finding fails
CI, including a complexity increase in an existing function. When a function
is fixed, remove its baseline line in the same change. The checker uses a
stable AST-context fingerprint and a sibling discriminator, so do not hand-edit
fingerprints. Do not add baseline entries. Use a narrow, single-line `oxlint`
suppression only for an intentional exception, with its reason in the comment
and pull request. Do not add a broad disable or raise the limit to accept new
code. Lower the limit in a separate cleanup wave as the remaining debt is
removed.

The required `Web complexity` check runs from the base branch and uses the
base branch checker and Oxlint toolchain against the pull-request source. Keep
the checker, trusted workflow, complexity rule, and Oxlint lock entries
unchanged in normal pull requests. Policy changes need a separate reviewed
update. The contributor-side `Web complexity candidate` check is only an early
local diagnostic.

## Cloud VM API runs on Effect

The Cloud VM control plane (`services/vms`, every route under `app/api/vm`)
is an Effect boundary. A new or changed VM endpoint follows it; a plain
`async` route that reaches Drizzle or a provider SDK directly is not accepted,
and neither is a PR that adds a VM route and leaves the migration "for later".

- Business logic is an Effect program in `services/vms/workflows.ts` (or a
  sibling module) that reads and writes through `VmRepository`, calls
  providers through `VmProviderGateway`, and bills through `VmBillingGateway`.
  Add repository methods for new queries; do not import `db/` or
  `services/coderouter/teamMachines` from a route.
- Failures are tagged errors in `services/vms/errors.ts`, added to the
  `VmWorkflowError` union. The responder table `vmWorkflowErrorResponders` in
  `services/vms/routeHelpers.ts` must then get an entry, or typecheck fails.
  Route-specific copy goes in an `onError` overrides table in the route.
- Routes run programs with `runVmRoute(program, { request, onError })` from
  `services/vms/routeWorkflow.ts` and branch on `run.ok`. No `Effect.runPromise`
  in a route, no `try { await runVmWorkflow(...) } catch`, no `isVm*Error`
  predicate chains, no per-route `Effect.provide`.
- `runVmWorkflow` (Promise, throws the typed error) is only for cron and
  account-deletion callers that have no HTTP error contract.
- Tests for a route mock the repository or the driver, not the workflow, so
  the Effect path is what runs. `tests/vm-route-workflow.test.ts` shows the
  boundary contract.

Plain TypeScript is still right for billing, coderouter, subrouter, vault,
pages, and scripts. The rule is about the VM control plane.
