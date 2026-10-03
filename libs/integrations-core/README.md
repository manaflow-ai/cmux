# @cmux/integrations-core

One implementation of generic integration ingestion and per-tool policy for cmux. It turns an OpenAPI 3 document, a GraphQL introspection result or an MCP `tools/list` result into a `Catalog` of tools, gives every tool an op class and a default action (Allow, Ask or Block), detects the auth methods the document declares, and resolves team and user policy rules for a tool address.

The cmux integrations app (`first-party-apps/integrations`) uses it for the local import preview and the policy display. The backend gateway will use the same code for authoritative ingestion at connect and refresh and for policy resolution at call time, so a rule set in the preview matches the tool the gateway runs.

License: MIT (`LICENSE`). The format extractors and the policy matcher are adapted from [executor](https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan. `NOTICE` lists every adapted file with its upstream paths; each adapted file starts with the same credit and a list of the cmux changes. Keep `LICENSE` and `NOTICE` with any copy or bundle of this code.

## What is in it

| Module | Content | Upstream |
| --- | --- | --- |
| `types.ts` | `ToolEntry`, `AuthMethod`, `Catalog`, `ToolAction`, `OpClass`, `CatalogKind` | cmux |
| `policy.ts` | op class per format, default action per op class, rule patterns, resolution, grant mapping | executor (see `NOTICE`) |
| `openapi.ts`, `openapi-paths.ts`, `openapi-auth.ts` | OpenAPI extraction, `group.leaf` tool paths, auth methods | executor |
| `graphql.ts` | introspection to tools | executor |
| `mcp.ts` | `tools/list` to tools, namespace | executor |
| `catalog.ts` | one importer (`importDocument`, `importText`), format detection, content digest | cmux |
| `index.ts` | root export: types, policy and importer; format modules as namespaces (`openapi`, `openapiPaths`, `openapiAuth`, `graphql`, `mcp`) | cmux |

Each module is also a subpath export (`@cmux/integrations-core/policy`, ...). The code is plain TypeScript with no runtime dependencies and no host globals (no `URL`, no `fetch`, no `crypto`), so it runs in Workers, Bun, Node and the QuickJS and JavaScriptCore app engines. It parses JSON only; YAML parsing, fetching a spec URL (with an SSRF guard), MCP clients and tool invocation belong to the gateway.

## Policy defaults (before any rule)

| Source | Op class | Default |
| --- | --- | --- |
| OpenAPI GET, HEAD, OPTIONS | read | Allow |
| OpenAPI POST, PUT, PATCH | mutate-shared | Ask |
| OpenAPI DELETE | destructive | Block |
| GraphQL query | read | Allow |
| GraphQL mutation | mutate-shared | Ask |
| GraphQL mutation named `delete…`, `remove…`, `destroy…`, `purge…`, `drop…`, `erase…`, `wipe…` | destructive | Block (name heuristic; GraphQL has no marker) |
| MCP `readOnlyHint: true` | read | Allow |
| MCP `destructiveHint: true` | destructive | Block |
| MCP without hints | mutate-shared | Ask (the MCP default for an un-annotated tool is "may write") |

In short: reads Allow, changes Ask, destructive Block. `defaultActionFor(opClass)` is the single mapping: `read` and `mutate-own` Allow; `destructive` and `money` Block; `mutate-shared`, `send-external` and `execute` Ask. First-class provider ops use the same mapping on the backend op's risk.

Rules are `{owner: team | user, pattern, action}`. Patterns: `*`, exact `ns.group.tool`, subtree `ns.group.*`, one segment `ns.*.delete`. Inside one owner the most specific rule wins; across owners the most restrictive action wins, so a user rule never loosens a team rule. A rule replaces the default (a team may allow a destructive tool). `grantFor(action)` maps to grants: Allow = grant with approval `none`, Ask = approval `per_call`, Block = no grant.

## Credentials

An `AuthMethod` names where a secret goes (header, query parameter, OAuth2 flow) and never holds the secret. The host collects the secret in its own UI and stores it as an opaque `cred_…` handle that only the gateway resolves.

## Tests

`bun test libs/integrations-core/test` runs ingestion and policy tests on the fixtures in `test/fixtures/`. No test makes a network call.

## Where this package lives

The repository has no top-level `packages/` directory, and on the default case-insensitive macOS file system `packages/` is the same directory as the Swift `Packages/`, so a new `packages/` would merge into it on Macs and split from it on Linux. `clients/ts/` is already a workspace glob of `backend/package.json`, so a new package there would change the backend lockfile, which this change does not touch. `libs/` is a new top-level directory outside `backend/`, `web/` and every BSL directory in the root `LICENSE`, and the package carries its own MIT `LICENSE`.

## Adoption by the backend

The backend lead does these steps in one backend PR:

1. Add `"../libs/integrations-core"` to `workspaces` in `backend/package.json`, then add `"@cmux/integrations-core": "workspace:*"` to `dependencies` of the gateway app that ingests catalogs and resolves policy.
2. Run `bun install` in `backend/` and commit the updated `backend/bun.lock` (CI installs with `--frozen-lockfile`).
3. Import from the package root, for example `import { importDocument, resolveEffectivePolicy, grantFor } from "@cmux/integrations-core"`. The sources are `.ts` with `.ts` import specifiers and already compile under `backend/tsconfig.base.json` (`moduleResolution: Bundler`, `allowImportingTsExtensions`, `noUncheckedIndexedAccess`, `verbatimModuleSyntax`); `tsconfig.json` here uses the same options.
4. Add `libs/integrations-core/**` to the `paths` filters of `.github/workflows/backend.yml`, and a step that runs `bun test test` in `libs/integrations-core`, so a change here reruns backend checks.
5. Record the package in `THIRD_PARTY_LICENSES.md` (or the backend's license inventory) as MIT with the executor copyright, and keep `NOTICE` with any bundle that is distributed.

Do not copy the sources into `backend/`: the backend depends on this package, so the app and the gateway keep one implementation. Changes to policy defaults change both, and the tests here are the contract.
