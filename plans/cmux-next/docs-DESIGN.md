# cmux-next docs

Decision (2026-10-24, user): cmux-next docs reuse the cmux.com docs infra. No new site.

## What exists

- Docs pages live in `web/app/[locale]/(landing)/docs/`. The sidebar is `web/app/[locale]/components/docs-nav-items.ts`. Search is Pagefind, built by `web/tools/build-docs-search.mjs`.
- Two docs channels. `release` (cmux.com/docs) builds from the latest release tag. `nightly` (cmux.com/docs/nightly) builds from `main`. `.github/workflows/docs-channels.yml` deploys them on a push to `main` or a `v*` tag. `web/app/lib/docs-channel.ts` hides a page from the release channel; Base already works this way.
- The keyboard shortcuts docs are generated from `plans/cmux-next/action-surfaces.json`, with a freshness test (`web/tests/docs-shortcuts.test.ts`).

## Design

cmux-next is a track inside the nightly channel, under `/docs/next`. It is not a third deployment.

- **Where.** `cmux.com/docs/nightly/next/...`. `cmux.com/docs/next` redirects there (`next.config.ts`). The release channel hides these pages and falls back to Getting Started, like Base. A release build never shows cmux-next docs until we choose to move them.
- **Why not a new zone.** A third Vercel project needs new secrets, rewrites, and a deploy workflow. A path in the nightly channel needs none of that, and the sidebar, search, "Copy page", and SEO headers work unchanged.
- **Language.** English only (`baseDocsLocales`), the same as Base.
- **Sidebar.** One section, "cmux-next", at the end, before Changelog.

## Pages

Hand-written, short, plain: `web/data/next-docs/pages.ts`. Getting started, Install and update, Home and Chief, Agents and subagents, Workspaces/panes/tabs/groups, Spaces and columns, Browser, Markdown and files, Remote machines and Tailscale, Cloud machines, Plans and credits (no prices until plans are on sale), MCP server.

Generated, so they cannot drift:

| Page | Source | Generated file |
| --- | --- | --- |
| CLI and MCP reference | `plans/cmux-next/action-surfaces.json` (what `cmux action list` reports): verbs with `cli: offered`, the `mcp` field says if `cmux mcp serve` also offers it | `web/data/next-docs/cli-reference.generated.json` |
| Command palette and Keyboard shortcuts | the same catalog: entries with `palette: offered` by palette section, with `default_shortcut` and the CLI command | `web/data/next-docs/palette-reference.generated.json` |
| Settings reference | `schemas/settings/settings-schema.json` (Settings page rows, hidden rows left out) | `web/data/next-docs/settings-reference.generated.json` |

Refresh with `bun web/scripts/export-next-docs.ts`. The base autofix runs it after the action exports change (`base-autofix.sh` step 1e1), and the settings export runs it with `--settings`; before 2026-10-27 only the shortcuts copy was regenerated, so these pages went stale. The CLI page's MCP column is the `app_` tool name, made by the same rule as `tool_name` in `cli/mcp/action_tools.rs`. `web/` never reads `plans/` or `schemas/` at build time, so the copies are committed.

## CI check

`web/tests/next-docs.test.ts` runs in the `bun test` step of `ci-web.yml` and in `cmux-next-docs-shortcuts.yml` (the backstop for direct pushes to feat-cmux-next). It fails when:

- either generated file is stale against its source;
- a `cmux ...` command in a hand-written page is not a real CLI verb;
- the sidebar and the page list disagree, or the release channel lists a cmux-next page.

## Deploy

- Preview: a Vercel preview of `web/` with `CMUX_DOCS_CHANNEL=nightly`, built from the pushed commit.
- Production: the nightly docs channel deploys when `main` receives the change (`docs-channels.yml`). feat-cmux-next reaches `main` by the normal sync. Nothing deploys from a push to feat-cmux-next alone.

## Not done yet

- Screenshots from Mac mini builds (the fleet capture path: `cmux-ci capture`). Pages have no images yet.
- Translations. English only.
- A page for subagents separate from Agents.
- Protocol MCP tools (`workspace_list`, `browser_navigate`, ...) are named on the MCP page by example only; `cmux mcp tools --json` is the full list.
