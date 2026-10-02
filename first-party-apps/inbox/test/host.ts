// Test harness: the platform's FakeHost loaded with the built app and wired
// to the mock feed owner, which emits `feed.changed` after every mutation.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { feedItems } from "./fixtures.ts"
import { MockFeed } from "./mock-feed.ts"

export const appSource = () => readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")

export interface Setup {
  settings?: Record<string, unknown>
  empty?: boolean
  unavailable?: boolean
  now?: number
}

const ok = (value: unknown) => ({ ok: true, body: { value } })
const err = (code: string, message = code) => ({ ok: false, body: { code, message, retryable: false } })

export function inboxHost(setup: Setup = {}) {
  const now = setup.now ?? Date.now()
  const host = new FakeHost(appSource(), { app: { id: "cmux/inbox", version: "0.2.0" }, apiVersion: "1.0.0", settings: setup.settings ?? {} })
  const owner = new MockFeed(setup.empty ? [] : feedItems(now))
  const storage = new Map<string, unknown>()
  const changed = (m: { revision: string; changedIds: string[] }) => {
    queueMicrotask(() => host.emit("feed.changed", { revision: m.revision, changed: m.changedIds, counts: owner.counts() }))
    return ok({ revision: m.revision, changed: m.changedIds.length })
  }
  const feedOp = (fn: (p: any) => unknown) => (p: any) => (setup.unavailable ? err("operation.unsupported") : fn(p))
  host.handlers["feed.list"] = feedOp((p) => ok(owner.list(p)))
  host.handlers["feed.counts"] = feedOp(() => ok(owner.counts()))
  host.handlers["feed.get"] = feedOp((p) => (owner.get(p.item) ? ok(owner.get(p.item)) : err("not_found")))
  host.handlers["feed.mark"] = feedOp((p) => changed(owner.mark(p)))
  host.handlers["feed.snooze"] = feedOp((p) => changed(owner.snooze(p)))
  host.handlers["feed.respond"] = feedOp((p) => changed(owner.respond(p)))
  host.handlers["action.run"] = () => ok(null)
  host.handlers["app.storage.get"] = (p) => ok(storage.get(p.key) ?? null)
  host.handlers["app.storage.set"] = (p) => {
    storage.set(p.key, p.value)
    return ok({})
  }
  return { host, owner, storage, now }
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
