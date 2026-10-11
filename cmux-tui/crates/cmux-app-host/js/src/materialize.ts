// Turns view descriptions into a retained scene: one scene node per view, one
// effect per live prop, keyed reconciliation for ForEach/Reorderable. Changes
// leave as minimal op batches (create, update, children, remove, root) per
// mount, sent once per flush.

import { createOwner, disposeOwner, effect, onAfterFlush, runWithOwner, signal, untrack, type Owner, type Read, type Write } from "./reactive.ts"
import { ViewNode, type Handler } from "./view.ts"

export type SceneOp =
  | { op: "create"; id: string; type: string; props: Record<string, unknown> }
  | { op: "update"; id: string; props: Record<string, unknown> }
  | { op: "children"; id: string; children: string[] }
  | { op: "remove"; id: string }
  | { op: "root"; id: string }

export const LIMITS = { nodesPerMount: 4096, depth: 64 }

interface MenuEntry {
  handler?: Handler
  children?: MenuEntry[]
}

interface NodeRecord {
  mount: Mount
  handlers: Record<string, Handler>
  menu: MenuEntry[] | null
  /** Current child ids, so a removal releases the whole subtree from the budget. */
  children: string[]
}

export class Mount {
  readonly owner: Owner
  readonly pending: SceneOp[] = []
  nodeCount = 0
  constructor(readonly id: string) {
    this.owner = createOwner(null)
  }
}

let nextNodeId = 1
const nodes = new Map<string, NodeRecord>()
const mounts = new Map<string, Mount>()
let sceneSink: (mountId: string, ops: SceneOp[]) => void = () => {}

export const setSceneSink = (sink: typeof sceneSink) => {
  sceneSink = sink
}

/** Sends every mount's pending ops (called after each reactive flush). */
export function sendPendingOps(): void {
  for (const mount of mounts.values()) {
    if (mount.pending.length === 0) continue
    const ops = mount.pending.splice(0)
    sceneSink(mount.id, ops)
  }
}
onAfterFlush(sendPendingOps)

const scalar = (v: unknown): unknown => {
  if (v === undefined) return null
  if (v === null || typeof v === "string" || typeof v === "boolean") return v
  if (typeof v === "number") return Number.isFinite(v) ? v : null
  if (typeof v === "object") return JSON.parse(JSON.stringify(v))
  return String(v)
}

/** Mounts `view` as the scene of `mountId`, replacing any previous mount with that id. */
export function mount(mountId: string, render: () => ViewNode): void {
  unmount(mountId)
  const m = new Mount(mountId)
  mounts.set(mountId, m)
  runWithOwner(m.owner, () => {
    const view = untrack(render)
    if (!(view instanceof ViewNode)) throw new Error("render must return a view (VStack, Text, ...)")
    const rootId = build(m, view, 0)
    m.pending.push({ op: "root", id: rootId })
  })
}

export function unmount(mountId: string): void {
  const m = mounts.get(mountId)
  if (!m) return
  disposeOwner(m.owner)
  for (const [id, rec] of nodes) if (rec.mount === m) nodes.delete(id)
  mounts.delete(mountId)
}

export const mountExists = (mountId: string) => mounts.has(mountId)
export const nodeRecord = (nodeId: string) => nodes.get(nodeId)

function setChildren(m: Mount, id: string, children: string[]) {
  const record = nodes.get(id)
  if (record) record.children = children
  m.pending.push({ op: "children", id, children })
}

function newNode(m: Mount, type: string, props: Record<string, unknown>): string {
  if (++m.nodeCount > LIMITS.nodesPerMount) throw new Error(`app.limit: more than ${LIMITS.nodesPerMount} scene nodes`)
  const id = `n${nextNodeId++}`
  m.pending.push({ op: "create", id, type, props })
  return id
}

function build(m: Mount, view: ViewNode, depth: number): string {
  if (depth > LIMITS.depth) throw new Error(`app.limit: scene deeper than ${LIMITS.depth}`)
  const staticProps: Record<string, unknown> = {}
  const live: Array<[string, () => unknown]> = []
  for (const [key, value] of Object.entries(view.props)) {
    if (typeof value === "function") live.push([key, value as () => unknown])
    else staticProps[key] = scalar(value)
  }
  for (const event of Object.keys(view.handlers)) staticProps[`on${event[0]!.toUpperCase()}${event.slice(1)}`] = true
  // Live props get their first value now so the create op is complete.
  const firstValues = new Map<string, unknown>()
  for (const [key, fn] of live) firstValues.set(key, scalar(untrack(fn)))
  for (const [key, v] of firstValues) staticProps[key] = v
  if (view.menu) staticProps.menu = null
  const id = newNode(m, view.type, staticProps)
  const record: NodeRecord = { mount: m, handlers: { ...view.handlers }, menu: null, children: [] }
  nodes.set(id, record)

  for (const [key, fn] of live) {
    let last = firstValues.get(key)
    let first = true
    effect(() => {
      const value = scalar(fn())
      if (first) {
        first = false
        return
      }
      if (JSON.stringify(value) === JSON.stringify(last)) return
      last = value
      m.pending.push({ op: "update", id, props: { [key]: value } })
    })
  }

  if (view.menu) bindMenu(m, id, record, view.menu)

  if (view.list) buildList(m, id, view, depth)
  else {
    const childIds: string[] = []
    for (const child of view.children) {
      if (child instanceof ViewNode) childIds.push(build(m, child, depth + 1))
      else childIds.push(buildDynamic(m, child, depth + 1))
    }
    if (childIds.length) setChildren(m, id, childIds)
  }
  return id
}

/** A function child: a Group whose single child is rebuilt when the function's result changes. */
function buildDynamic(m: Mount, fn: () => unknown, depth: number): string {
  const id = newNode(m, "Group", {})
  nodes.set(id, { mount: m, handlers: {}, menu: null, children: [] })
  let current: { owner: Owner; ids: string[] } | null = null
  effect(() => {
    const result = fn()
    untrack(() => {
      if (current) {
        disposeOwner(current.owner)
        for (const old of current.ids) removeNode(m, old)
      }
      const owner = createOwner()
      const views = (Array.isArray(result) ? result : [result]).filter((v): v is ViewNode => v instanceof ViewNode)
      const ids = runWithOwner(owner, () => views.map((v) => build(m, v, depth + 1)))
      current = { owner, ids }
      setChildren(m, id, ids)
    })
  })
  return id
}

/** Removes a node and its subtree: one `remove` op (the host drops the subtree), every record and budget slot released. */
function removeNode(m: Mount, id: string) {
  m.pending.push({ op: "remove", id })
  const stack = [id]
  while (stack.length) {
    const next = stack.pop()!
    const record = nodes.get(next)
    if (record) stack.push(...record.children)
    if (nodes.delete(next)) m.nodeCount--
  }
}

interface Row {
  key: string
  owner: Owner
  setItem: Write<unknown>
  nodeId: string
}

function buildList(m: Mount, containerId: string, view: ViewNode, depth: number) {
  const { spec, template } = view.list!
  let rows = new Map<string, Row>()
  let order: string[] = []
  effect(() => {
    const items = spec.items() ?? []
    untrack(() => {
      const next = new Map<string, Row>()
      const nextOrder: string[] = []
      items.forEach((item, index) => {
        const key = String(spec.key(item, index))
        if (next.has(key)) return // duplicate keys: first wins, like the old runtime
        const existing = rows.get(key)
        if (existing) {
          existing.setItem(item)
          next.set(key, existing)
        } else {
          const owner = createOwner()
          const [read, write] = signal<unknown>(item, { equals: () => false })
          const nodeId = runWithOwner(owner, () => build(m, template(read as Read<unknown>, key), depth + 1))
          next.set(key, { key, owner, setItem: (v) => write(() => v), nodeId })
        }
        nextOrder.push(key)
      })
      for (const [key, row] of rows) {
        if (next.has(key)) continue
        disposeOwner(row.owner)
        removeNode(m, row.nodeId)
      }
      const changed = nextOrder.length !== order.length || nextOrder.some((k, i) => k !== order[i] || rows.get(k)?.nodeId !== next.get(k)?.nodeId)
      rows = next
      order = nextOrder
      if (changed) setChildren(m, containerId, nextOrder.map((k) => next.get(k)!.nodeId))
    })
  })
  // Rows emit `move` with the row key, which is what onMove(id, index) expects.
}

function bindMenu(m: Mount, id: string, record: NodeRecord, source: ViewNode[] | (() => ViewNode[])) {
  let last = ""
  effect(() => {
    const items = typeof source === "function" ? source() : source
    const entries: MenuEntry[] = []
    const payload = items.map((item) => menuItem(item, entries))
    record.menu = entries
    const json = JSON.stringify(payload)
    if (json === last) return
    const first = last === ""
    last = json
    if (first) {
      // Patch the create op still in the queue when possible, else send an update.
      const create = m.pending.find((op) => op.op === "create" && op.id === id) as { props: Record<string, unknown> } | undefined
      if (create) {
        create.props.menu = payload
        return
      }
    }
    m.pending.push({ op: "update", id, props: { menu: payload } })
  })
}

const read = (v: unknown) => scalar(typeof v === "function" ? (v as () => unknown)() : v)

function menuItem(item: ViewNode, entries: MenuEntry[]): Record<string, unknown> {
  if (item.type === "Divider") {
    entries.push({})
    return { divider: true }
  }
  const title = read(item.props.title ?? item.props.text ?? "")
  const out: Record<string, unknown> = { title }
  if (item.props.destructive) out.destructive = true
  if (item.props.disabled !== undefined) out.disabled = read(item.props.disabled)
  if (item.props.symbol !== undefined) out.symbol = read(item.props.symbol)
  if (item.type === "Menu" && Array.isArray(item.menu)) {
    const children: MenuEntry[] = []
    out.children = item.menu.map((child) => menuItem(child, children))
    entries.push({ children })
  } else {
    entries.push({ handler: item.handlers.tap })
  }
  return out
}

/** Resolves a menu index path to its handler. */
export function menuHandler(record: NodeRecord, path: number[]): Handler | undefined {
  let level = record.menu
  let entry: MenuEntry | undefined
  for (const index of path) {
    entry = level?.[index]
    level = entry?.children ?? null
  }
  return entry?.handler
}
