// State shared by every mount in this VM: projects, items, filters, the
// selected item and the one planned change. No polling: skill.watch and
// mcp_server.watch (agent CLIs edit these files too) trigger a reload.

import type { ChangeEvent, ChangeState } from "./model/change.ts"
import { reduceChange } from "./model/change.ts"
import { DEFAULT_FILTER, type Filter, type Item, type McpServer, type Project, type Skill } from "./model/items.ts"
import { call, type OpError } from "./ops.ts"

const [items, setItems] = signal<Item[]>([])
const [projects, setProjects] = signal<Project[]>([])
const [currentRoot, setCurrentRoot] = signal<string | null>(null)
const [errors, setErrors] = signal<{ skills: OpError | null; mcp: OpError | null }>({ skills: null, mcp: null })
const [loaded, setLoaded] = signal(false)
const [filter, setFilter] = signal<Filter>(DEFAULT_FILTER)
const [selected, setSelected] = signal<string | null>(null)
const [change, setChange] = signal<ChangeState>({ phase: "idle" })
const [notice, setNotice] = signal<string | null>(null)

export { items, projects, currentRoot, errors, loaded, filter, setFilter, selected, setSelected, change, notice, setNotice }

export const dispatchChange = (ev: ChangeEvent) => setChange((s) => reduceChange(s, ev))
export const projectLabel = (root: string | null | undefined) => projects().find((p) => p.root === root)?.label ?? null

let started = false

export function start(): void {
  if (started) return
  started = true
  void load()
  cmux.events.on("skill.watch", () => void loadItems())
  cmux.events.on("mcp_server.watch", () => void loadItems())
}

/** The focused workspace's folder (a root handle), then the items. */
export async function load(): Promise<void> {
  const ws = await call<Array<{ id: string; name: string; focused: boolean }>>("workspace.list")
  const focused = ws.ok ? ws.value.find((w) => w.focused) : null
  const root = focused ? await call<{ root: string; label: string }>("workspace.root", { workspace: focused.id }) : null
  const list = root?.ok && root.value.root ? [{ root: root.value.root, label: root.value.label || focused!.name, workspace: focused!.id }] : []
  setProjects(list)
  setCurrentRoot(list[0]?.root ?? null)
  await loadItems()
  setLoaded(true)
}

export async function loadItems(): Promise<void> {
  const root = currentRoot()
  const params = root ? { roots: [root] } : {}
  const [s, m] = await Promise.all([call<{ skills: Skill[] }>("skill.list", params), call<{ servers: McpServer[] }>("mcp_server.list", params)])
  const next: Item[] = [...(s.ok ? (s.value.skills ?? []).map((x) => ({ ...x, kind: "skill" as const })) : []), ...(m.ok ? (m.value.servers ?? []).map((x) => ({ ...x, kind: "mcp" as const })) : [])]
  setItems(next)
  setErrors({ skills: s.ok ? null : s.error, mcp: m.ok ? null : m.error })
}
