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
| `catalog.ts` | one importer (`importDocument`, `importText`), format detection, content digest, the 2 MB catalog cap, stdio MCP refusal | cmux |
| `auth.ts` | credential kinds of a connection (`auth {kind}`) and the auth choices an add flow offers | cmux |
| `egress.ts` | SSRF pre-checks on URL text (private, loopback, link-local, ULA, CGNAT; every IPv4 literal form; IPv4-embedding IPv6), the 10 MB and 30 s limits, the `generic_hosts` matcher | cmux |
| `mcp-names.ts` | `/v1/mcp` tool names (`<namespace>__<path>`, at most 64 characters, hash suffix) and the tool listing (opt-in connections, Block hidden, Ask `per_call`) | cmux |
| `text.ts` | FNV-1a, UTF-8 length, code-point compare | cmux |
| `index.ts` | root export: types, policy and importer; format modules as namespaces (`openapi`, `openapiPaths`, `openapiAuth`, `graphql`, `mcp`) | cmux |

Each module is also a subpath export (`@cmux/integrations-core/policy`, ...). The code is plain TypeScript with no runtime dependencies and no host globals (no `URL`, no `fetch`, no `crypto`), so it runs in Workers, Bun, Node and the QuickJS and JavaScriptCore app engines. It parses JSON only; YAML parsing, fetching a spec URL (with the SSRF guard after DNS and every redirect), the Streamable HTTP MCP client and tool invocation belong to the gateway. `egress.ts` checks only the URL text, so a client can refuse obvious bad input with the gateway's error codes; it never replaces the gateway's check. MCP servers are remote over Streamable HTTP only: `importDocument` refuses stdio launch configs with `import.mcp_stdio`.

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

Rules are `{owner: team | user, pattern, action}`; team rules live in ConnectionDO and user rules in UserDO. Patterns: `*`, exact `ns.group.tool`, subtree `ns.group.*`, one segment `ns.*.delete`. Inside one owner the most specific rule wins; across owners the most restrictive action wins, so a user rule never loosens a team rule. A rule replaces the default, with one exception: only a rule for the exact tool may loosen a Block default (destructive and money ops). A broader rule that would allow or ask counts as the default for its owner, so a subtree rule never unblocks a destructive tool. The backend lead must confirm this exception, since the gateway uses the same `resolveEffectivePolicy`. `grantFor(action)` maps to grants: Allow = grant with approval `none`, Ask = approval `per_call`, Block = no grant.

## Credentials

An `AuthMethod` names where a secret goes (header, query parameter, OAuth2 flow) and never holds the secret. A connection records only its `CredentialKind` (`api_key`, `bearer`, `basic`, `headers`, `oauth2_code` with PKCE and, for MCP, dynamic client registration, `oauth2_client_credentials`, or `none`). The host collects the secret in its own secure sheet; the gateway seals it as an opaque `cred_…` handle bound to (user, app id, host pattern) and is the only process that resolves it.

## MCP endpoint names

One endpoint per principal (`/v1/mcp`). `mcpToolName(namespace, path)` returns `<namespace>__<path>` with the path's dots as `-`, in `[A-Za-z0-9_-]{1,64}`. A name that would lose information or be longer than 64 characters is cut and ends with `_` plus 8 hex digits of FNV-1a over the full address. `assignMcpToolNames` names a set in code-point order of address then key and gives a colliding entry the next salted hash, so the result does not depend on input order. `mcpListedTools` names every tool of the opted-in connections (so blocking one tool never renames another), then drops Block tools.

## Tests

`bun test libs/integrations-core/test` runs ingestion, policy, egress and MCP naming tests on the fixtures in `test/fixtures/`. No test makes a network call.

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
