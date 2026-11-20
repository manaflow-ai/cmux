// Mounts every view of the three looks (claude, codex, studio) in cmux-app-host's fake host, with
// only the ops their manifests' scopes grant, and fails on any script error or empty mount.
// Run from cmux-tui/crates/cmux-app-host/js (it needs dist/cmux-app-runtime.js):
//   bun test ../../../../examples/customize-demo/looks/check/views.test.ts
import { readFileSync } from "node:fs"
import { describe, expect, test } from "bun:test"
import { FakeHost } from "../../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const looks = new URL("../", import.meta.url)
const scopesTable = new URL("../../../../cmux-tui/crates/cmux-app-host/generated/scopes.json", import.meta.url)

const NOW = Date.now()
const CHATS = [
  { id: "a", title: "Fix the login race", harness: "claude", state: "working", unread: false, project: "web", cwd: "/src/web", workspace: "w1", step: "Running tests", error: null, since_ms: NOW - 40_000, updated_ms: NOW - 40_000, created_ms: NOW - 3_600_000, pull_requests: [] },
  { id: "b", title: "Ship the theme packs", harness: "codex", state: "input", unread: true, project: "cmux", cwd: "/src/cmux", workspace: "w2", step: null, error: null, since_ms: NOW - 600_000, updated_ms: NOW - 600_000, created_ms: NOW - 7_200_000, pull_requests: ["https://github.com/o/r/pull/1"] },
  { id: "c", title: "Old notes", harness: "claude", state: "idle", unread: false, project: "cmux", cwd: "/src/cmux", workspace: null, step: null, error: null, since_ms: null, updated_ms: NOW - 3 * 86_400_000, created_ms: NOW - 4 * 86_400_000, pull_requests: [] }
]
const USAGE = {
  state: "ready",
  providers: [
    { id: "claude", summary: { usable: 1 }, pace: { verdict: "onPace" }, accounts: [{ weekly_left_pct: 62, session_left_pct: 35, extra_usage_usd: 0 }] },
    { id: "codex", summary: { usable: 2 }, pace: { verdict: "under" }, accounts: [{ weekly_left_pct: 80, session_left_pct: 90 }, { weekly_left_pct: 70, session_left_pct: 55 }] }
  ]
}
const CARD = { title: "web", age: "2m", status: "Working", statusSinceMs: NOW - 40_000, facts: [{ kind: "task", text: "Fix the login race" }, { kind: "branch", text: "fix/login", sinceMs: NOW - 60_000 }] }

function host(look: string) {
  const dir = new URL(`${look}/customize/`, looks)
  const manifest = JSON.parse(readFileSync(new URL("cmux-app.json", dir), "utf8"))
  const scopes = Object.keys(manifest.scopes ?? {})
  const table: Record<string, { scope: string }> = JSON.parse(readFileSync(scopesTable, "utf8")).ops
  const ops = Object.entries(table).filter(([, v]) => v.scope === "none" || scopes.includes(v.scope)).map(([op]) => op)
  const h = new FakeHost(readFileSync(new URL("main.js", dir), "utf8"), { app: { id: "local/customize", version: "1.0.0" }, apiVersion: "1.0.0", ops })
  const ok = (value: unknown) => () => ({ ok: true, body: { value } })
  h.handlers["agent_chat.list"] = ok({ chats: CHATS })
  h.handlers["workspace.list"] = ok([{ id: "w1", name: "web", focused: true }])
  h.handlers["usage_app.status"] = ok(USAGE)
  h.handlers["app.storage.get"] = ok(null)
  h.handlers["app.storage.set"] = ok(null)
  h.handlers["toast.show"] = ok(null)
  return { h, manifest }
}

const texts = (h: FakeHost, m: string) => {
  const tree = h.tree(m)
  const out: string[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    for (const key of ["text", "title", "subtitle", "placeholder"]) if (typeof n.props[key] === "string") out.push(n.props[key] as string)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

for (const look of ["claude", "codex", "studio"]) {
  describe(look, () => {
    const { manifest } = host(look)
    for (const [iface, spec] of Object.entries(manifest.implements) as Array<[string, { export: string }]>) {
      test(`${iface} (${spec.export}) mounts and draws`, async () => {
        const { h } = host(look)
        const ctx = iface === "cmux.session.info.section/1" ? { session_id: "a", cwd: "/src/web", branch: "fix/login", harness: "claude" } : iface === "cmux.hovercard/1" ? { target: { kind: "workspace", id: "w1" }, card: CARD } : {}
        expect(h.mount("m", spec.export, ctx)).toBe("")
        await h.settle(10)
        const drawn = texts(h, "m")
        expect(drawn.length).toBeGreaterThan(0)
        const errors = h.logs.filter(([level]) => level === "error")
        expect(errors).toEqual([])
        console.log(`${look} ${spec.export}: ${drawn.slice(0, 8).join(" | ")}`)
      })
    }
  })
}

// Leo's NIGHTLY has about a thousand chats: a row per chat ran the studio's VM past its 250 ms step
// and the host stopped it (Threads "couldn't load", New Tab fell back to cmux's own page). The list
// draws a bounded number of rows whatever the number of chats.
test("studio's thread list stays bounded with 2000 chats", async () => {
  const { h } = host("studio")
  const many = Array.from({ length: 2000 }, (_, i) => ({ ...CHATS[i % 3], id: `c${i}`, title: `Chat ${i}`, project: `p${i % 40}` }))
  h.handlers["agent_chat.list"] = () => ({ ok: true, body: { value: { chats: many } } })
  expect(h.mount("m", "renderThreads", {})).toBe("")
  await h.settle(10)
  expect(h.logs.filter(([level]) => level === "error")).toEqual([])
  const nodes = h.tree("m").nodes.size
  expect(nodes).toBeLessThan(1500)
  expect(texts(h, "m").some((t) => t.includes("more · Command-K"))).toBe(true)
})
