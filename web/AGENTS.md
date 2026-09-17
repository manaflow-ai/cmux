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
