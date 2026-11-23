// Mounts every view of the four redone last-demo setups (cockpit, collection, focus, tiling) in
// cmux-app-host's fake host, with only the ops their manifests' scopes grant, and fails on any
// script error or empty mount. The same check as ../../looks/check/views.test.ts.
// Run from cmux-tui/crates/cmux-app-host/js (it needs dist/cmux-app-runtime.js):
//   bun test ../../../../examples/customize-demo/last-demo/check/views.test.ts
import { readFileSync } from "node:fs"
import { describe, expect, test } from "bun:test"
import { FakeHost } from "../../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const root = new URL("../", import.meta.url)
const scopesTable = new URL("../../../../cmux-tui/crates/cmux-app-host/generated/scopes.json", import.meta.url)

const NOW = Date.now()
const CHATS = [
  { id: "a", title: "Fix the login race", harness: "claude", state: "working", unread: false, project: "web", cwd: "/src/web", workspace: "w1" },
  { id: "b", title: "Ship the theme packs", harness: "codex", state: "input", unread: true, project: "cmux", cwd: "/src/cmux", workspace: "w2" },
  { id: "c", title: "Flaky test sweep", harness: "claude", state: "failed", unread: false, project: "cmux", cwd: "/src/cmux", workspace: null }
]
const USAGE = {
  state: "ready",
  providers: [
    { id: "claude", summary: { usable: 1 }, pace: { verdict: "onPace" }, accounts: [{ weekly_left_pct: 62, session_left_pct: 35, extra_usage_usd: 0 }] },
    { id: "codex", summary: { usable: 2 }, pace: { verdict: "over" }, accounts: [{ weekly_left_pct: 30, session_left_pct: 90, extra_usage_usd: 4.5 }, { weekly_left_pct: 20, session_left_pct: 55 }] }
  ]
}
const WORKSPACES = [
  { id: "w1", name: "web", focused: true },
  { id: "w2", name: "cmux", focused: false }
]

function host(setup: string) {
  const dir = new URL(`${setup}/customize/`, root)
  const manifest = JSON.parse(readFileSync(new URL("cmux-app.json", dir), "utf8"))
  const scopes = Object.keys(manifest.scopes ?? {})
  const table: Record<string, { scope: string }> = JSON.parse(readFileSync(scopesTable, "utf8")).ops
  const ops = Object.entries(table).filter(([, v]) => v.scope === "none" || scopes.includes(v.scope)).map(([op]) => op)
  const h = new FakeHost(readFileSync(new URL("main.js", dir), "utf8"), { app: { id: "local/customize", version: "2.0.0" }, apiVersion: "1.0.0", ops })
  const ok = (value: unknown) => () => ({ ok: true, body: { value } })
  h.handlers["agent_chat.list"] = ok({ chats: CHATS })
  h.handlers["workspace.list"] = ok(WORKSPACES)
  h.handlers["pane.list"] = ok([{ id: "p1", focused: true }, { id: "p2", focused: false }])
  h.handlers["tab.list"] = ok([
    { id: "t1", pane_id: "p1", index: 0, name: "zsh", content_kind: "terminal", focused: true },
    { id: "t2", pane_id: "p2", index: 0, name: "Docs", content_kind: "browser", focused: false }
  ])
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

for (const setup of ["cockpit", "collection", "focus", "tiling"]) {
  describe(setup, () => {
    const { manifest } = host(setup)
    for (const [iface, spec] of Object.entries(manifest.implements) as Array<[string, { export: string }]>) {
      test(`${iface} (${spec.export}) mounts and draws`, async () => {
        const { h } = host(setup)
        expect(h.mount("m", spec.export, {})).toBe("")
        await h.settle(10)
        const drawn = texts(h, "m")
        // The tiling rows view only decorates the app's own rows: it draws no text of its own.
        if (iface !== "cmux.sidebar.rows/1") expect(drawn.length).toBeGreaterThan(0)
        const errors = h.logs.filter(([level]) => level === "error")
        expect(errors).toEqual([])
        console.log(`${setup} ${spec.export}: ${drawn.slice(0, 10).join(" | ")}`)
      })
    }
  })
}
