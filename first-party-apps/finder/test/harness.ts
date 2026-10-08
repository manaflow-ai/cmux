// FakeHost setup for the Finder app: loads dist/main.js and answers ops from a preview fixture.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

type Fixture = { ops: Record<string, unknown> }
export const fixture = (name: string) => JSON.parse(readFileSync(join(import.meta.dir, `../preview/${name}.json`), "utf8")) as Fixture
const source = () => readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")

/** Answers like the preview harness: a value, `{$sequence: [...]}` (last one repeats) or `{$error: {...}}`. */
export function answer(value: unknown) {
  let i = 0
  return () => {
    let v = value as Record<string, unknown> | unknown
    if (v && typeof v === "object" && "$sequence" in (v as object)) {
      const seq = (v as { $sequence: unknown[] }).$sequence
      v = seq[Math.min(i++, seq.length - 1)]
    }
    if (v && typeof v === "object" && "$error" in (v as object)) return { ok: false, body: (v as { $error: unknown }).$error }
    return { ok: true, body: { value: structuredClone(v) } }
  }
}

export function makeHost(name: string, settings: Record<string, unknown> = {}, overrides: Record<string, unknown> = {}) {
  const host = new FakeHost(source(), { app: { id: "cmux/finder", version: "0.1.0" }, apiVersion: "1.0.0", settings, locale: "en" })
  for (const [op, value] of Object.entries({ ...fixture(name).ops, ...overrides })) host.handlers[op] = answer(value)
  return host
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

export async function tap(host: FakeHost, mount: string, text: string) {
  const list = visible(host, mount)
  const idx = list.findIndex(([, n]) => n.props.title === text || n.props.text === text)
  if (idx < 0) throw new Error(`no node "${text}"`)
  const { nodes } = host.tree(mount)
  const parentOf = new Map<string, string>()
  for (const [id, n] of nodes) for (const c of n.children) parentOf.set(c, id)
  let id: string | undefined = list[idx]![0]
  while (id && !nodes.get(id)!.props.onTap) id = parentOf.get(id)
  if (!id) throw new Error(`"${text}" is not tappable`)
  host.dispatch(mount, id, "tap", { gesture: "gst_test" })
  await host.settle(10)
}

export const callsOf = (host: FakeHost, op: string) => host.calls.filter((c) => c.name === op)
