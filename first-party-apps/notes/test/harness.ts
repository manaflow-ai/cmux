// Shared FakeHost setup: the built app wired to the mock notes server, the
// file broker and workspaces. Every committed change goes out on `note.watch`.
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import type { NoteEvent } from "../src/notes.ts"
import { NotesServer, ServerError, WORKSPACES, type Seed } from "./mock-server.ts"

export const source = () => readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")

/** Ops that would move focus or selection outside the app. */
export const FOCUS_OPS = ["workspace.focus", "pane.focus", "tab.focus", "screen.focus", "terminal.input.focus", "browser.activate", "app.pane.open"]

const NOW = 1_790_000_000_000
export const SEEDS: Seed[] = [
  { id: "note_a000000000000000", title: "Release checklist", body: "- [x] tag\n- [ ] notes\n- [ ] announce", pinned: true, created: NOW - 9e6, updated: NOW - 9e6 },
  { id: "note_b000000000000000", body: "Ideas\nfaster search\nexport to folder", created: NOW - 8e6, updated: NOW - 5e6 },
  { id: "note_pad0000000000000", body: "check flaky test\nport 3001 busy", scratchpad: true, workspace: { id: "workspace_api", name: "api" }, created: NOW - 7e6, updated: NOW - 1e6, by: "agent" }
]

export interface Options {
  settings?: Record<string, unknown>
  seeds?: Seed[]
  unavailable?: boolean
  /** Files the user "picks" in the import panel: name -> text. */
  pickFiles?: Record<string, string>
}

const ok = (value: unknown) => ({ ok: true, body: { value } })
const err = (code: string, message = code, details?: unknown) => ({ ok: false, body: { code, message, details, retryable: false } })

export function makeHost(opts: Options = {}) {
  const host = new FakeHost(source(), { app: { id: "cmux/notes", version: "0.2.0" }, apiVersion: "1.0.0", settings: opts.settings ?? {} })
  const server = new NotesServer(opts.seeds ?? SEEDS, () => NOW)
  const emit = (...events: Array<NoteEvent | null | undefined>) => {
    for (const ev of events) if (ev) queueMicrotask(() => host.emit("note.watch", ev))
  }
  const serve = (fn: (p: any, o: any) => unknown) => (p: any, o: any) => {
    if (opts.unavailable) return err("operation.unsupported", "no handler")
    try {
      return ok(fn(p, o))
    } catch (e) {
      if (e instanceof ServerError) return err(e.code, e.message, e.details)
      throw e
    }
  }
  host.handlers["note.list"] = serve((p) => server.list(p))
  host.handlers["note.get"] = serve((p) => ({ note: structuredClone(server.get(p.note)) }))
  host.handlers["note.create"] = serve((p, o) => {
    const r = server.create(p, o?.idempotencyKey)
    emit(r.event)
    return { note: r.note }
  })
  host.handlers["note.capture"] = serve((p) => {
    const [first, ...rest] = String(p.text).trim().split("\n")
    const r = server.create({ title: first, body: rest.join("\n"), workspace: p.workspace })
    emit(r.event)
    return { note: r.note }
  })
  host.handlers["note.append"] = serve((p) => {
    const r = server.append(p)
    emit(...r.events)
    return { note: r.note }
  })
  host.handlers["note.update"] = serve((p) => {
    const r = server.update(p)
    emit(r.event)
    return { note: r.note }
  })
  host.handlers["note.delete"] = serve((p) => {
    emit(server.delete(p))
    return {}
  })
  host.handlers["note.search"] = serve((p) => ({ results: server.list({ query: p.query, limit: p.limit }).notes.map((n) => ({ id: n.id, title: n.title, snippet: n.preview, open: { command: "cmux/notes#open", args: { id: n.id } } })) }))
  host.handlers["document.edit"] = serve((p) => {
    const r = server.edit(p)
    emit(r.event)
    return { revision: r.revision }
  })
  // The file broker: the panel needs a gesture; handles name only what the user picked.
  host.handlers["fs.pick"] = serve((p, o) => {
    if (!o?.gesture) throw new ServerError("gesture.required", "the file panel opens only from a user action")
    if (p.mode === "folder") return { root: "root_export1", name: "Notes export" }
    const entries = Object.entries(opts.pickFiles ?? {}).map(([name, text]) => {
      server.files.set(`root_import1/${name}`, text)
      return { path: name, name, size: text.length }
    })
    return { root: "root_import1", name: "Downloads", entries }
  })
  host.handlers["fs.write"] = serve((p) => {
    if (p.root !== "root_export1" || String(p.path).includes("/") || String(p.path).startsWith(".")) throw new ServerError("fs.outside_root", "path outside the picked folder")
    server.written.push({ root: p.root, path: p.path, text: p.text })
    return { path: p.path }
  })
  host.handlers["fs.read"] = serve((p) => ({ text: server.files.get(`${p.root}/${p.path}`) ?? (() => { throw new ServerError("selector.not_found", "no such file") })() }))
  host.handlers["app.pane.open"] = () => ok({ tab_id: "tab_editor" })
  host.handlers["workspace.list"] = () => ok(WORKSPACES)
  host.handlers["app.settings.set"] = (p) => {
    host.global.__cmuxAppSetSettings(JSON.stringify({ ...(opts.settings ?? {}), ...p.values }))
    return ok({})
  }
  return { host, server, emit }
}

/** Runs an app command and returns its completion body. */
export async function run(host: FakeHost, exportName: string, args: Record<string, unknown> = {}) {
  const cb = Math.floor(Math.random() * 1e9)
  host.global.__cmuxAppRunCommand(exportName, JSON.stringify(args), cb)
  for (let i = 0; i < 50 && !host.commandResults.has(cb); i++) await host.settle(2)
  const r = host.commandResults.get(cb)
  if (!r) throw new Error(`${exportName} did not finish`)
  return r
}

type SceneNode = { type: string; props: Record<string, unknown>; children: string[] }

/** Nodes reachable from the root, in order. */
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
/** A user tap or menu pick (the host attaches a gesture token to every user event). */
export const tap = (host: FakeHost, mount: string, node: string) => host.dispatch(mount, node, "tap", { gesture: `g_${node}` })
export const menu = (host: FakeHost, mount: string, node: string, path: number[]) => host.dispatch(mount, node, "menu", { path, gesture: `g_${node}` })
