#!/usr/bin/env bun
// Writes the preview harness fixtures with times relative to now (countdowns
// go stale, so rerun this before taking screenshots):
//   bun first-party-apps/usage/preview/build.ts
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { DEFAULT_RATIOS, grant, historyValue, proposedScopes, usageValue } from "./fixtures.ts"

const here = new URL(".", import.meta.url).pathname
const now = Date.now()
const base = { grant, scopes: proposedScopes }
const ok = { ...base, ops: { "account.list": usageValue(now), "account.usage": historyValue(now, DEFAULT_RATIOS), "notification.create": { id: "notification_1" } } }

const files: Record<string, unknown> = {
  // Claude on pace with an account in error, Codex over pace, one keyed provider.
  "normal.json": ok,
  // The router has not answered for 47 minutes; the server keeps the last reading.
  "stale.json": {
    ...base,
    ops: {
      "account.list": usageValue(now, { fetchedAgo: 47 * 60_000, stale: true, error: { code: "router.timeout", message: "The router did not answer within 90 s." } }),
      "account.usage": historyValue(now, DEFAULT_RATIOS, { fetchedAgo: 47 * 60_000 })
    }
  },
  // The first reading: no older snapshot yet, so the pace waits.
  "pending.json": { ...base, ops: { "account.list": usageValue(now), "account.usage": { snapshots: [] } } },
  // The router answered but the hosted router failed: a source error.
  "source-error.json": {
    ...base,
    ops: {
      "account.list": usageValue(now, { sources: [{ id: "subrouter", ok: true, error: null }, { id: "coderouter", ok: false, error: { code: "coderouter.unreachable", message: "unreachable" } }] }),
      "account.usage": historyValue(now, { claude: 0.5, codex: 1.0 })
    }
  },
  // This build has no usage server yet.
  "unavailable.json": { ...base, ops: { "account.list": { $error: { code: "operation.unsupported", message: "account.list is not supported by this host yet" } } } },
  // No accounts in the router.
  "empty.json": { ...base, ops: { "account.list": { schema_version: 1, fetched_at_ms: String(now), sources: [], providers: {} }, "account.usage": { snapshots: [] } } }
}
for (const [name, value] of Object.entries(files)) writeFileSync(join(here, name), `${JSON.stringify(value, null, 2)}\n`)
console.log(`wrote ${Object.keys(files).length} fixtures`)
