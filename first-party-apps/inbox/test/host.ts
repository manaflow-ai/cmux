// Test harness: the platform's FakeHost loaded with the built app and the
// shared fixtures, plus in-memory app storage and a path-aware GitHub gateway.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { githubData, sessionData } from "./fixtures.ts"

export const appSource = () => readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")

export interface Setup {
  settings?: Record<string, unknown>
  github?: "ok" | "notGranted" | "unavailable"
  empty?: boolean
  replyScope?: boolean
  now?: number
}

const ok = (value: unknown) => ({ ok: true, body: { value } })
const err = (code: string, message = code) => ({ ok: false, body: { code, message, retryable: false } })

export function inboxHost(setup: Setup = {}) {
  const now = setup.now ?? Date.now()
  const host = new FakeHost(appSource(), { app: { id: "cmux/inbox", version: "0.1.0" }, apiVersion: "1.0.0", settings: { maxAgeDays: 0, ...setup.settings } })
  const storage = new Map<string, unknown>()
  const s = sessionData(now)
  const g = githubData(now)
  host.handlers["notification.list"] = () => ok(setup.empty ? [] : s.notifications)
  host.handlers["agent.list"] = () => ok(setup.empty ? [] : s.agents)
  host.handlers["terminal.list"] = () => ok(s.terminals)
  host.handlers["workspace.list"] = () => ok(s.workspaces)
  host.handlers["screen.list"] = () => ok(s.screens)
  host.handlers["pane.list"] = () => ok(s.panes)
  host.handlers["tab.list"] = () => ok(s.tabs)
  host.handlers["terminal.screen.read"] = () => ok(s.screen)
  host.handlers["terminal.get"] = (p) => ok(s.terminals.find((x) => x.id === p.terminal))
  host.handlers["tab.focus"] = (p) => ok({ id: p.tab })
  host.handlers["action.run"] = () => ok(null)
  host.handlers["notification.ack"] = (p) => ok({ client_id: p.client_id, acknowledged: p.notifications, unknown: [] })
  host.handlers["terminal.input.write"] = () => (setup.replyScope === false ? err("scope.missing", "this app does not hold terminal:execute") : ok({}))
  host.handlers["app.storage.get"] = (p) => ok(storage.get(p.key) ?? null)
  host.handlers["app.storage.set"] = (p) => {
    storage.set(p.key, p.value)
    return ok({})
  }
  host.handlers["integration.request"] = (p) => {
    if (setup.github === "notGranted") return err("scope.missing", "this app does not hold integration:github:read")
    if (setup.github === "unavailable") return err("operation.unsupported")
    const path = String(p.path)
    if (setup.empty) return ok({ items: [] })
    if (path.includes("review-requested")) return ok(g.review)
    if (path.includes("status%3Afailure")) return ok(g.failing)
    if (path.includes("mentions")) return ok(g.mention)
    if (path.includes("/pulls/")) return ok(g.pull)
    if (path.includes("/check-runs")) return ok(g.checks)
    return err("not_found")
  }
  return { host, storage, now }
}

type SceneNode = { id: string; type: string; props: Record<string, unknown> }

/** Nodes reachable from the root, in visual (children) order. */
export function walk(host: FakeHost, mount: string): SceneNode[] {
  const { root, nodes } = host.tree(mount)
  const out: SceneNode[] = []
  const visit = (id: string) => {
    const n = nodes.get(id)
    if (!n) return
    out.push({ id, type: n.type, props: n.props })
    for (const c of n.children) visit(c)
  }
  visit(root)
  return out
}

export const texts = (host: FakeHost, mount: string) =>
  walk(host, mount)
    .map((n) => n.props.title ?? n.props.text)
    .filter((v): v is string => typeof v === "string" && v.length > 0)

export const rows = (host: FakeHost, mount: string) => walk(host, mount).filter((n) => n.type === "Row").map((n) => String(n.props.title))

export const nodeWith = (host: FakeHost, mount: string, type: string, title: string) =>
  walk(host, mount).find((n) => n.type === type && (n.props.title === title || n.props.text === title))?.id

/** Runs a command export and waits for its result. */
export async function command(host: FakeHost, name: string, args: unknown = {}) {
  const cb = 1000 + host.commandResults.size
  host.global.__cmuxAppRunCommand(name, JSON.stringify(args), cb)
  for (let i = 0; i < 50 && !host.commandResults.has(cb); i++) await host.settle(2)
  return host.commandResults.get(cb)!
}

export function fireTimers(host: FakeHost, pick: (t: { ms: number; repeat: boolean }) => boolean) {
  for (const [id, t] of [...host.timers]) {
    if (!pick(t)) continue
    if (!t.repeat) host.timers.delete(id)
    host.global.__cmuxAppTimer(id)
  }
}
