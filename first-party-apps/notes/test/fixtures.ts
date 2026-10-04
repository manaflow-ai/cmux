// Invented, neutral notes for the preview harness. `bun first-party-apps/notes/test/fixtures.ts --write`
// regenerates preview/*.json from the mock notes server, with times relative to now.
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { NotesServer, WORKSPACES, type Seed } from "./mock-server.ts"

const H = 3_600_000

export function previewSeeds(now: number): Seed[] {
  return [
    { id: "note_pad0000000000001", body: "rate limiter test flakes under load\n- [x] repro with 50 workers\n- [ ] check retry budget\nport 3001 busy: stop the old dev server first", scratchpad: true, workspace: { id: "workspace_api", name: "api" }, created: now - 30 * H, updated: now - 0.2 * H, by: "agent" },
    { id: "note_release000000001", title: "Release checklist", body: "- [x] tag the build\n- [x] update the changelog\n- [ ] announce in the team channel\n- [ ] watch error rates for an hour", pinned: true, created: now - 50 * H, updated: now - 3 * H },
    { id: "note_runbook000000001", body: "# Deploy runbook\n1. freeze merges\n2. run the migration on staging\n3. promote\n> roll back with the previous image tag", workspace: { id: "workspace_web", name: "web" }, created: now - 70 * H, updated: now - 26 * H },
    { id: "note_ideas00000000001", body: "Ideas\nfaster search across notes\nexport a folder per workspace", created: now - 90 * H, updated: now - 50 * H },
    { id: "note_triage000000001", title: "Flaky test triage", body: "3 of 40 runs failed in the payments suite\nsuspect: shared clock in the retry test", created: now - 5 * H, updated: now - 1 * H, by: "agent" },
    { id: "note_padweb000000001", body: "try the new chart colors", scratchpad: true, workspace: { id: "workspace_web", name: "web" }, created: now - 20 * H, updated: now - 8 * H }
  ]
}

const scope = (name: string, cls: string) => ({ scope: name, class: cls })
/** Proposed ops are unknown to the preview engine's scope table: name their scopes. */
const SCOPES = {
  "note.list": scope("notes:read", "read"),
  "note.get": scope("notes:read", "read"),
  "note.search": scope("notes:read", "read"),
  "note.append": scope("notes:write", "mutation"),
  "note.create": scope("notes:write", "mutation"),
  "note.update": scope("notes:write", "mutation"),
  "document.edit": scope("notes:write", "mutation"),
  "fs.pick": scope("fs:read", "read"),
  "app.pane.open": scope("workspace:write", "mutation")
}

export function previewFixture(now: number, options: { empty?: boolean; unavailable?: boolean; bodies?: string[] } = {}) {
  const server = new NotesServer(options.empty ? [] : previewSeeds(now), () => now)
  const unsupported = { $error: { code: "operation.unsupported", message: "the notes server is not running on this host" } }
  const ops: Record<string, unknown> = options.unavailable
    ? { "note.list": unsupported }
    : {
        "note.list": server.list({ limit: 2000 }),
        ...(options.bodies?.length ? { "note.get": { $sequence: options.bodies.map((id) => ({ note: server.get(id) })) } } : {})
      }
  ops["workspace.list"] = WORKSPACES
  return { grant: ["workspace:read", "mcp:expose", "notes:read", "notes:write", "fs:read", "workspace:write"], scopes: SCOPES, ops }
}

if (import.meta.main && process.argv.includes("--write")) {
  const dir = join(import.meta.dir, "../preview")
  const now = Date.now()
  const write = (name: string, value: unknown) => writeFileSync(join(dir, `${name}.json`), `${JSON.stringify(value, null, 2)}\n`)
  write("scratchpad", previewFixture(now, { bodies: ["note_pad0000000000001", "note_release000000001"] }))
  write("list", previewFixture(now, { bodies: ["note_release000000001"] }))
  write("editor", previewFixture(now))
  write("empty", previewFixture(now, { empty: true }))
  write("unavailable", previewFixture(now, { unavailable: true }))
  console.log(`wrote ${dir}`)
}
