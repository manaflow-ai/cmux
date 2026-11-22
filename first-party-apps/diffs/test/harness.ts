// FakeHost setup for the Diffs app: loads dist/main.js and answers ops from a preview fixture.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

export const source = () => readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")
export const fixture = (name: string) => JSON.parse(readFileSync(join(import.meta.dir, `../preview/${name}.json`), "utf8")) as { ops: Record<string, unknown> }

export function makeHost(settings: Record<string, unknown> = {}, ops: Record<string, unknown> = fixture("split").ops) {
  const host = new FakeHost(source(), { app: { id: "cmux/diffs", version: "0.1.0" }, apiVersion: "1.0.0", settings })
  for (const [name, value] of Object.entries(ops)) host.handlers[name] = () => ({ ok: true, body: { value: structuredClone(value) } })
  return host
}

export async function run(host: FakeHost, exportName: string, args: Record<string, unknown> = {}) {
  const cb = Math.floor(Math.random() * 1e9)
  host.global.__cmuxAppRunCommand(exportName, JSON.stringify(args), cb)
  await host.settle(20)
  const r = host.commandResults.get(cb)
  if (!r) throw new Error(`${exportName} did not finish`)
  return r
}

type SceneNode = { type: string; props: Record<string, unknown>; children: string[] }

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

export const texts = (host: FakeHost, mount: string) => visible(host, mount).map(([, n]) => n.props.title ?? n.props.text).filter((v): v is string => typeof v === "string" && v !== "")

export const findText = (host: FakeHost, mount: string, text: string) => visible(host, mount).find(([, n]) => n.props.title === text || n.props.text === text)?.[0]

/** Taps the first visible node with this text or title (a Button's label is a child Text). */
export async function tap(host: FakeHost, mount: string, text: string) {
  const list = visible(host, mount)
  const idx = list.findIndex(([, n]) => n.props.title === text || n.props.text === text)
  if (idx < 0) throw new Error(`no node "${text}"`)
  // Walk up: the tappable node is the nearest ancestor (or self) with onTap.
  const { nodes } = host.tree(mount)
  const parentOf = new Map<string, string>()
  for (const [id, n] of nodes) for (const c of n.children) parentOf.set(c, id)
  let id: string | undefined = list[idx]![0]
  while (id && !nodes.get(id)!.props.onTap) id = parentOf.get(id)
  if (!id) throw new Error(`"${text}" is not tappable`)
  host.dispatch(mount, id, "tap")
  await host.settle(10)
}
