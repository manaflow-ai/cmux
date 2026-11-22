// FakeHost setup for the Integrations app: loads dist/main.js and answers ops from a preview fixture.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

export const source = () => readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")
export const fixture = (name: string) => JSON.parse(readFileSync(join(import.meta.dir, `../preview/${name}.json`), "utf8")) as { ops: Record<string, unknown> }

type Answer = (params: Record<string, unknown>) => { ok: boolean; body: unknown }

/** Fixture ops answer every call; `{$sequence}` answers successive calls; `{$error}` fails. Extra handlers override. */
export function makeHost(settings: Record<string, unknown> = {}, ops: Record<string, unknown> = fixture("connections").ops, extra: Record<string, Answer> = {}) {
  const host = new FakeHost(source(), { app: { id: "cmux/integrations", version: "0.1.0" }, apiVersion: "1.0.0", settings })
  for (const [name, value] of Object.entries(ops)) {
    const v = value as { $sequence?: unknown[]; $error?: unknown }
    if (v && Array.isArray(v.$sequence)) {
      let i = 0
      host.handlers[name] = () => ({ ok: true, body: { value: structuredClone(v.$sequence![Math.min(i++, v.$sequence!.length - 1)]) } })
    } else if (v && v.$error) host.handlers[name] = () => ({ ok: false, body: v.$error })
    else host.handlers[name] = () => ({ ok: true, body: { value: structuredClone(value) } })
  }
  Object.assign(host.handlers, extra)
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

/** Visible strings in tree order: title or text, then a Row's subtitle. */
export const texts = (host: FakeHost, mount: string) =>
  visible(host, mount)
    .flatMap(([, n]) => [n.props.title ?? n.props.text, n.props.subtitle])
    .filter((v): v is string => typeof v === "string" && v !== "")

/** Taps the first visible node with this text or title, or its nearest tappable ancestor. */
export async function tap(host: FakeHost, mount: string, text: string, nth = 0) {
  const list = visible(host, mount).filter(([, n]) => n.props.title === text || n.props.text === text)
  if (list.length <= nth) throw new Error(`no node "${text}"`)
  const { nodes } = host.tree(mount)
  const parentOf = new Map<string, string>()
  for (const [id, n] of nodes) for (const c of n.children) parentOf.set(c, id)
  let id: string | undefined = list[nth]![0]
  while (id && !nodes.get(id)!.props.onTap) id = parentOf.get(id)
  if (!id) throw new Error(`"${text}" is not tappable`)
  host.dispatch(mount, id, "tap", { gesture: `g-${++gestures}` })
  await host.settle(10)
}

let gestures = 0
/** The gesture token the last tap carried. */
export const lastGesture = () => `g-${gestures}`

export async function submit(host: FakeHost, mount: string, placeholder: string, text: string) {
  const id = visible(host, mount).find(([, n]) => n.type === "TextField" && n.props.placeholder === placeholder)?.[0]
  if (!id) throw new Error(`no field "${placeholder}"`)
  host.dispatch(mount, id, "submit", { text })
  await host.settle(10)
}
