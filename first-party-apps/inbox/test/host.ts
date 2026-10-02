// Test harness: the platform's FakeHost loaded with the built app and wired
// to the mock feed owner. After every committed op the owner's event goes out
// on the feed stream, as the app host would forward it.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import type { FeedEvent } from "../src/feed.ts"
import { feedItems, WORKSPACES } from "./fixtures.ts"
import { MockFeed, OwnerReject } from "./mock-feed.ts"

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
  const host = new FakeHost(appSource(), { app: { id: "cmux/inbox", version: "0.3.0" }, apiVersion: "1.0.0", settings: setup.settings ?? {} })
  const owner = new MockFeed(setup.empty ? [] : feedItems(now))
  const storage = new Map<string, unknown>()
  const actions: Array<{ id: string; args: unknown; gesture: unknown }> = []
  const emit = (ev: FeedEvent | null) => {
    if (ev) queueMicrotask(() => host.emit("feed", ev))
  }
  /** Runs an owner mutation: its event goes out on the stream, a refusal comes back as the owner's error. */
  const mutate = (fn: () => FeedEvent | null, value: unknown) => {
    try {
      emit(fn())
      return ok(value)
    } catch (e) {
      if (e instanceof OwnerReject) return err(e.code, e.message)
      throw e
    }
  }
  const feedOp = (fn: (p: any, o: any) => unknown) => (p: any, o: any) => (setup.unavailable ? err("operation.unsupported") : fn(p, o))
  host.handlers["feed.list"] = feedOp((p) => ok(owner.list(p)))
  host.handlers["feed.counts"] = feedOp(() => ok(owner.counts()))
  host.handlers["feed.get"] = feedOp((p) => (owner.get(p.item) ? ok({ item: structuredClone(owner.get(p.item)) }) : err("selector.not_found")))
  host.handlers["feed.answer"] = feedOp((p, o) => mutate(() => owner.answer(p, o?.gesture), { item: owner.get(p.item) }))
  host.handlers["feed.cancel"] = feedOp((p, o) => mutate(() => owner.cancel(p, o?.gesture ? "user" : "script"), { item: owner.get(p.item) }))
  host.handlers["feed.read"] = feedOp((p) => mutate(() => owner.read(p), { items: [] }))
  host.handlers["feed.archive"] = feedOp((p) => mutate(() => owner.archive(p), { items: [] }))
  host.handlers["feed.unarchive"] = feedOp((p) => mutate(() => owner.unarchive(p), { items: [] }))
  host.handlers["feed.snooze"] = feedOp((p) => mutate(() => owner.snooze(p), { items: [] }))
  // The feed's own open action reads the item and runs its open target (the owner's read event follows).
  host.handlers["action.run"] = (p, o) => {
    actions.push({ id: p.id, args: p.args, gesture: o?.gesture })
    if (p.id === "feed.openItem") return mutate(() => owner.read({ items: [p.args.item] }), null)
    return ok(null)
  }
  host.handlers["workspace.list"] = () => ok(WORKSPACES)
  host.handlers["app.settings.set"] = (p) => {
    host.global.__cmuxAppSetSettings(JSON.stringify({ ...(setup.settings ?? {}), ...p.values }))
    return ok({})
  }
  host.handlers["app.storage.get"] = (p) => ok(storage.get(p.key) ?? null)
  host.handlers["app.storage.set"] = (p) => {
    storage.set(p.key, p.value)
    return ok({})
  }
  return { host, owner, storage, actions, now, emit }
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

/** A user tap (the host attaches a gesture token to every user event). */
export const tap = (host: FakeHost, mount: string, node: string) => host.dispatch(mount, node, "tap", { gesture: `g_${node}` })
export const menu = (host: FakeHost, mount: string, node: string, path: number[]) => host.dispatch(mount, node, "menu", { path, gesture: `g_${node}` })
