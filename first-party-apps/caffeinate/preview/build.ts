#!/usr/bin/env bun
// Writes the preview harness fixtures with times relative to now (countdowns
// go stale, so rerun this before taking screenshots):
//   bun first-party-apps/caffeinate/preview/build.ts
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { commandAssertion, grant, hourAssertion, listValue, processes, proposedScopes, stoppedAssertion, terminals } from "./fixtures.ts"

const here = new URL(".", import.meta.url).pathname
const now = Date.now()
const base = { grant, scopes: proposedScopes }
const terminalOps = { "terminal.list": terminals, "terminal.process.get": { $sequence: ["terminal_7", "terminal_8", "terminal_9", "terminal_7", "terminal_8", "terminal_9"].map((id) => processes[id]) } }

const files: Record<string, unknown> = {
  // Three assertions: a timed one, one bound to a running build, one until stopped (its system part paused on battery).
  "active.json": { ...base, ops: { "power.assertion.list": listValue(now, [hourAssertion(now), commandAssertion(now), stoppedAssertion(now)], { power_source: "battery" }), ...terminalOps } },
  // Nothing keeps the Mac awake.
  "idle.json": { ...base, ops: { "power.assertion.list": listValue(now, []), ...terminalOps } },
  // This build has no power capability yet.
  "unavailable.json": { ...base, ops: { "power.assertion.list": { $error: { code: "operation.unsupported", message: "power.assertion.list is not supported by this host yet" } } } }
}
for (const [name, value] of Object.entries(files)) writeFileSync(join(here, name), `${JSON.stringify(value, null, 2)}\n`)
