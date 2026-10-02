// Shared FakeHost setup: loads the built app with in-memory storage and workspaces.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

export const source = () => readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")

export const WORKSPACES = [
  { id: "workspace_api", session_id: "s", name: "api", index: 0, focused: true },
  { id: "workspace_web", session_id: "s", name: "web", index: 1, focused: false }
]

/** Mutation ops that would move focus or selection outside the app. */
export const FOCUS_OPS = ["workspace.focus", "pane.focus", "tab.focus", "screen.focus", "terminal.input.focus", "browser.activate"]

export function makeHost(settings: Record<string, unknown> = {}, storage: Record<string, unknown> = {}) {
  const host = new FakeHost(source(), { app: { id: "cmux/notes", version: "0.1.0" }, apiVersion: "1.0.0", settings })
  const kv = new Map<string, unknown>(Object.entries(storage))
  host.handlers["app.storage.get"] = (p) => ({ ok: true, body: { value: kv.has(p.key) ? structuredClone(kv.get(p.key)) : null } })
  host.handlers["app.storage.set"] = (p) => {
    kv.set(p.key, structuredClone(p.value))
    return { ok: true, body: { value: null } }
  }
  host.handlers["workspace.list"] = () => ({ ok: true, body: { value: WORKSPACES } })
  return { host, kv }
}

/** Runs an app command and returns its completion body. */
export async function run(host: FakeHost, exportName: string, args: Record<string, unknown> = {}, ctx: Record<string, unknown> = {}) {
  const cb = Math.floor(Math.random() * 1e9)
  host.global.__cmuxAppRunCommand(exportName, JSON.stringify(args), cb)
  await host.settle(20)
  void ctx
  const r = host.commandResults.get(cb)
  if (!r) throw new Error(`${exportName} did not finish`)
  return r
}

type SceneNode = { type: string; props: Record<string, unknown>; children: string[] }

/** Nodes reachable from the root, in order (the fake tree keeps removed subtrees' descendants). */
export function visible(host: FakeHost, mount: string): Array<[string, SceneNode]> {
  const { root, nodes } = host.tree(mount)
  const out: Array<[string, SceneNode]> = []
  const walk = (id: string) => {
    const n = nodes.get(id)
    if (!n) return
    out.push([id, n])
    n.children.forEach(walk)
  }
  walk(root)
  return out
}

export const texts = (host: FakeHost, mount: string) => visible(host, mount).map(([, n]) => n.props.title ?? n.props.text).filter((v) => typeof v === "string" && v)

export const nodesOf = (host: FakeHost, mount: string, type: string) => visible(host, mount).filter(([, n]) => n.type === type)

export const findVisible = (host: FakeHost, mount: string, pred: (n: SceneNode) => boolean) => visible(host, mount).find(([, n]) => pred(n))?.[0]
