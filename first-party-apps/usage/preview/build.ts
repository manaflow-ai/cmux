#!/usr/bin/env bun
// Writes the preview harness fixtures with times relative to now (reset
// countdowns go stale, so rerun this before taking screenshots):
//   bun first-party-apps/usage/preview/build.ts
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { grant, poolsValue, proposedScopes, usageValue } from "./fixtures.ts"

const here = new URL(".", import.meta.url).pathname
const now = Date.now()
const base = { grant, scopes: proposedScopes }
const ok = { ...base, ops: { "usage.get": usageValue(now), "coderouter.usage.get": poolsValue(now), "notification.create": { id: "notification_1" } } }

const files: Record<string, unknown> = {
  "menuPercent.json": ok,
  "menuMeters.json": ok,
  "sidebarOnly.json": ok,
  // The service could not refresh for 47 minutes and Codex's sign-in expired.
  "stale.json": { ...base, ops: { "usage.get": usageValue(now, { fetchedAgo: 47 * 60_000, stale: true, codexError: true }) } },
  // This build has no usage service yet.
  "unavailable.json": { ...base, ops: { "usage.get": { $error: { code: "operation.unsupported", message: "usage.get is not supported by this host yet" } } } },
  // Signed in nowhere.
  "empty.json": { ...base, ops: { "usage.get": { revision: "1", accounts: [] } } }
}
for (const [name, value] of Object.entries(files)) writeFileSync(join(here, name), `${JSON.stringify(value, null, 2)}\n`)
console.log(`wrote ${Object.keys(files).length} fixtures`)
