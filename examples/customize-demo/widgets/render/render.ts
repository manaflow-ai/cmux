// Mounts the widgets app in the reference fake host with fixtures and prints each scene tree as text.
import { readFileSync } from "node:fs"
const R = new URL("../../../../", import.meta.url).pathname.replace(/\/$/, "")
const { FakeHost } = await import(`${R}/cmux-tui/crates/cmux-app-host/js/test/fake-host.ts`)
const src = readFileSync(`${R}/examples/customize-demo/widgets/widgets/customize/main.js`, "utf8")
import { gh } from "./gh.ts"
const now = Date.now()
const scopes = Object.keys(JSON.parse(readFileSync(`${R}/examples/customize-demo/widgets/widgets/customize/cmux-app.json`, "utf8")).scopes)
const table = JSON.parse(readFileSync(`${R}/cmux-tui/crates/cmux-app-host/generated/scopes.json`, "utf8")).ops
const ops = Object.entries(table).filter(([, v]: any) => v.scope === "none" || scopes.includes(v.scope) || (v.scope === "net:<host>")).map(([op]) => op)
const host = new FakeHost(src, { app: { id: "local/customize", version: "1.0.0" }, apiVersion: "1.0.0", ops })
const ok = (value: unknown) => ({ ok: true, body: { value } })
const chats = [
  { id: "c1", title: "Fix sidebar glass", state: "working", project: "cmux", updated_ms: now - 120000, harness: "claude" },
  { id: "c2", title: "Review usage card", state: "input", project: "cmux", updated_ms: now - 600000, harness: "codex" },
  { id: "c3", title: "Land widgets demo", state: "idle", project: "hq", updated_ms: now - 3600000, harness: "claude" }
]
const prs = [{ id: 1, number: 46900, title: "Widgets demo profile", url: "https://github.com/o/r/pull/46900", repo: "o/cmux", author: "me", draft: false, state: "open", headRef: "lane/widgets", headSha: "a", additions: 420, deletions: 12, checks: { state: "pending", failing: 0, pending: 3, passing: 17 }, review: "review-required", updatedAt: "2026-11-19T10:00:00Z" },
  { id: 2, number: 46880, title: "Glass sidebar", url: "u", repo: "o/cmux", author: "me", draft: false, state: "open", headRef: "x", headSha: "b", additions: 88, deletions: 40, checks: { state: "failing", failing: 1, pending: 0, passing: 22 }, review: "changes-requested", updatedAt: "2026-11-19T09:00:00Z" }]
host.fallback = (name: string, params: any) => {
  if (name === "agent.list") return ok([{ id: "a1", state: "working" }])
  if (name === "agent_chat.list") return ok({ chats })
  if (name === "chat.list") return ok(chats)
  if (name === "usage_app.status") return ok({ state: "ready", providers: [
    { id: "claude", summary: { usable: 2 }, pace: { verdict: "under" }, accounts: [{ weekly_left_pct: 72, session_left_pct: 64 }, { weekly_left_pct: 58, session_left_pct: 90 }] },
    { id: "codex", summary: { usable: 1 }, pace: { verdict: "over" }, accounts: [{ weekly_left_pct: 31, session_left_pct: 22, extra_usage_usd: 4.5 }] }] })
  if (name === "app.storage.get") return ok(params?.key === "place" ? { name: "San Francisco", latitude: 37.77, longitude: -122.42 } : null)
  if (name === "net.fetch" && String(params.url).includes("forecast")) return ok({ status: 200, headers: {}, body: JSON.stringify({ current: { temperature_2m: 14.2, weather_code: 2 }, daily: { temperature_2m_max: [17], temperature_2m_min: [9] } }) })
  if (name === "integration.request") return ok(gh(params.path))
  return { ok: false, body: { code: "operation.unsupported", message: name, retryable: false } }
}
function print(mount: string) {
  const { root, nodes } = host.tree(mount)
  const lines: string[] = []
  const walk = (id: string, depth: number) => {
    const n = nodes.get(id); if (!n) return
    const p = n.props
    const label = [p.title, p.text, p.value, p.message, p.subtitle, p.symbol, p.accessory, p.badge].filter((v) => v !== undefined && v !== null && typeof v !== "object").join(" | ")
    lines.push(`${"  ".repeat(depth)}${n.type}${label ? ": " + label : ""}`)
    for (const c of n.children) walk(c, depth + 1)
  }
  walk(root, 0)
  return lines.join("\n")
}
for (const [m, e, ctx] of [["s", "renderSidebar", {}], ["i", "renderSessionInfo", { session_id: "c1", harness: "claude", cwd: "/x/cmux", branch: "lane/widgets" }], ["p", "renderPage", {}]] as const) {
  host.mount(m, e, ctx)
}
await host.settle(40)
for (let g = 0; g < 200; g++) { const due = [...host.timers].filter(([, t]: any) => !t.repeat); if (!due.length) break; for (const [id] of due) { host.timers.delete(id); host.global.__cmuxAppTimer(id) } await host.settle() }
await host.settle(20)
for (const m of ["s", "i", "p"]) console.log(`==== ${m}\n` + print(m))
console.log("==== errors\n" + host.logs.filter(([l]: [string]) => l === "error").map((x: string[]) => x.join(" ")).join("\n"))
console.log("==== calls\n" + [...new Set(host.calls.map((c: any) => c.name))].join(" "))
