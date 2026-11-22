// State shared by every mount in this VM: memory roots per machine, the files
// in each, the open document, search hits and the one pending edit. Files are
// reached only through root and document handles. No polling: memory.watch
// reloads a root's listing; document.watch marks the open file changed.

import { classify, type Classification, fileRank, type RootKind } from "./model/kinds.ts"
import { type ReviewEvent, type ReviewState, reduceReview } from "./model/review.ts"
import { call, type OpError } from "./ops.ts"

export type Root = { root: string; kind: RootKind; label: string; machine: string; machine_label?: string | null; workspace?: string | null }
export type MemFile = { root: string; path: string; size: number; modified: number; revision: string; project_label?: string | null; c: Classification }
export type OpenDoc = { root: string; path: string; doc: string; revision: string; text: string; changed: boolean }
export type Hit = { root: string; path: string; line: number; text: string }

const [roots, setRoots] = signal<Root[]>([])
const [files, setFiles] = signal<Record<string, MemFile[]>>({})
const [errors, setErrors] = signal<Record<string, OpError>>({})
const [rootsError, setRootsError] = signal<OpError | null>(null)
const [loaded, setLoaded] = signal(false)
const [selected, setSelected] = signal<{ root: string; path: string } | null>(null)
const [open, setOpen] = signal<OpenDoc | null>(null)
const [openError, setOpenError] = signal<OpError | null>(null)
const [query, setQuery] = signal("")
const [hits, setHits] = signal<Hit[] | null>(null)
const [review, setReview] = signal<ReviewState>({ phase: "idle" })
const [texts, setTexts] = signal<Record<string, string>>({})

export { roots, files, errors, rootsError, loaded, selected, open, openError, query, hits, review, texts }

export const dispatchReview = (ev: ReviewEvent) => setReview((s) => reduceReview(s, ev))
export const fileKey = (root: string, path: string) => `${root}\u0000${path}`
export const allFiles = () => roots().flatMap((r) => files()[r.root] ?? [])
export const rootOf = (id: string) => roots().find((r) => r.root === id) ?? null

let started = false

export function start(): void {
  if (started) return
  started = true
  void load()
  cmux.events.on("memory.watch", (p) => {
    const root = (p as { root?: string } | null)?.root
    if (typeof root === "string") void loadFiles(root)
  })
  cmux.events.on("document.watch", (p) => {
    const m = p as { doc?: string; revision?: string } | null
    const cur = open()
    if (!cur || m?.doc !== cur.doc || m.revision === cur.revision) return
    // Idle: show the new text. During a review: keep the diff, say so; Save checks the revision.
    if (review().phase === "idle") void select(cur.root, cur.path)
    else setOpen({ ...cur, changed: true })
  })
}

/** Machines (fallback: this one), each machine's memory roots, then each root's files. */
export async function load(): Promise<void> {
  const ms = await call<Array<{ id: string; name: string; status: string }>>("machine.list")
  const machines = ms.ok ? ms.value.filter((m) => m.status !== "stopped") : [{ id: "", name: "", status: "running" }]
  const all: Root[] = []
  let firstError: OpError | null = null
  for (const m of machines) {
    const r = await call<{ machine?: string; roots: Root[] }>("memory.roots", m.id ? { machine: m.id } : {})
    if (r.ok) all.push(...(r.value.roots ?? []).map((x) => ({ ...x, machine: x.machine ?? m.id, machine_label: x.machine_label ?? (m.name || null) })))
    else firstError ??= r.error
  }
  setRoots(all)
  setRootsError(all.length ? null : firstError)
  for (const r of all) await loadFiles(r.root)
  if (!selected()) {
    const first = allFiles()[0]
    if (first) await select(first.root, first.path)
  }
  setLoaded(true)
}

export async function loadFiles(root: string): Promise<void> {
  const r = await call<{ files: Array<Omit<MemFile, "c" | "root">> }>("memory.list", { root })
  const kind = rootOf(root)?.kind ?? "project"
  if (!r.ok) {
    setErrors((e) => ({ ...e, [root]: r.error }))
    return
  }
  const list = (r.value.files ?? []).flatMap((f) => {
    const c = classify(kind, f.path)
    return c ? [{ ...f, root, c }] : []
  })
  list.sort((a, b) => fileRank(kind, a.path, a.c) - fileRank(kind, b.path, b.c) || a.path.localeCompare(b.path))
  setFiles((all) => ({ ...all, [root]: list }))
  setErrors((e) => {
    const { [root]: _, ...rest } = e
    return rest
  })
}

/** Reads a document by handle: open (handle + revision), then read (text). */
export async function readDoc(root: string, path: string): Promise<{ ok: true; doc: OpenDoc } | { ok: false; error: OpError }> {
  const o = await call<{ doc: string; revision: string }>("document.open", { root, path })
  if (!o.ok) return o
  const r = await call<{ text: string; revision: string }>("document.read", { doc: o.value.doc })
  if (!r.ok) return r
  return { ok: true, doc: { root, path, doc: o.value.doc, revision: r.value.revision ?? o.value.revision, text: r.value.text ?? "", changed: false } }
}

/** Selects a file and reads it; the promise settles when the text is shown. */
export async function select(root: string, path: string): Promise<void> {
  setSelected({ root, path })
  const r = await readDoc(root, path)
  const sel = selected()
  if (!sel || sel.root !== root || sel.path !== path) return
  if (r.ok) {
    setOpen(r.doc)
    setOpenError(null)
    setTexts((all) => ({ ...all, [fileKey(root, path)]: r.doc.text }))
  } else {
    setOpen(null)
    setOpenError(r.error)
  }
}

/** The entries design reads every file once (sequentially, a bounded number). */
export async function loadAllTexts(limit = 30): Promise<void> {
  for (const f of allFiles().slice(0, limit)) {
    if (texts()[fileKey(f.root, f.path)] !== undefined) continue
    const r = await readDoc(f.root, f.path)
    if (r.ok) setTexts((all) => ({ ...all, [fileKey(f.root, f.path)]: r.doc.text }))
  }
}

export function rememberText(root: string, path: string, text: string, revision: string): void {
  setTexts((all) => ({ ...all, [fileKey(root, path)]: text }))
  const cur = open()
  if (cur && cur.root === root && cur.path === path) setOpen({ ...cur, text, revision, changed: false })
}

export async function search(q: string): Promise<void> {
  setQuery(q)
  if (!q.trim()) {
    setHits(null)
    return
  }
  const r = await call<{ hits: Hit[] }>("memory.search", { roots: roots().map((x) => x.root), query: q.trim(), limit: 50 })
  if (r.ok) setHits(r.value.hits ?? [])
  else {
    // Without the owner's search, match file names and the texts already read.
    const lower = q.toLowerCase()
    const local: Hit[] = []
    for (const f of allFiles()) {
      if (f.path.toLowerCase().includes(lower)) local.push({ root: f.root, path: f.path, line: 0, text: f.path })
      const text = texts()[fileKey(f.root, f.path)]
      text?.split("\n").forEach((l, i) => {
        if (l.toLowerCase().includes(lower)) local.push({ root: f.root, path: f.path, line: i + 1, text: l.trim() })
      })
    }
    setHits(local)
  }
}
