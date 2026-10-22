// Compatibility layer for old cmux JS custom sidebars (~/.config/cmux/sidebars/*.js):
// `sidebar(fn)`, `data.<key>()`, `cmux(method, params)`, `openURL(url)`, `log()`.
// `cmux app import-sidebar` wraps such a file into a `local/<name>` app whose
// `sidebars` contribution renders the export `sidebar`.

import { call, live, log } from "./cmux.ts"
import { computed, type Read } from "./reactive.ts"

type RawWorkspace = { id: string; name?: string; focused?: boolean; index?: number } & Record<string, unknown>
type RawAgent = { workspace_id?: string; workspace?: string; state?: string; status?: string } & Record<string, unknown>
type RawNotification = { workspace_id?: string; read?: boolean } & Record<string, unknown>

/** An agent's state in the old vocabulary (idle, working, needs_input, ended). */
const agentStatus = (a: RawAgent): string => {
  const state = a.state ?? a.status ?? "idle"
  return state === "blocked" ? "needs_input" : state === "done" ? "ended" : state === "working" ? "working" : "idle"
}

/**
 * `workspace.list` rows in the old shape, keeping every new field: `title` (= name), `selected`
 * (= focused), `unread` (unread notifications of the workspace), `agents` and `status`
 * (working, needs-attention or idle, from its agents).
 */
export function classicWorkspaces(workspaces: RawWorkspace[], agents: RawAgent[], notifications: RawNotification[]): unknown[] {
  const unread = new Map<string, number>()
  for (const n of notifications) if (!n.read && n.workspace_id) unread.set(n.workspace_id, (unread.get(n.workspace_id) ?? 0) + 1)
  const byWorkspace = new Map<string, RawAgent[]>()
  for (const a of agents) {
    const ws = a.workspace_id ?? a.workspace
    if (!ws) continue
    const list = byWorkspace.get(ws)
    if (list) list.push(a)
    else byWorkspace.set(ws, [a])
  }
  return workspaces.map((w) => {
    const own = (byWorkspace.get(w.id) ?? []).map((a) => ({ ...a, status: agentStatus(a) }))
    const status = own.some((a) => a.status === "needs_input") ? "needs-attention" : own.some((a) => a.status === "working") ? "working" : "idle"
    return { ...w, title: w.title ?? w.name ?? "", selected: w.focused === true, unread: unread.get(w.id) ?? 0, agents: own, status }
  })
}

/** Old data keys mapped onto live catalog reads. Created on first use so unused keys cost nothing. */
const definitions: Record<string, () => Read<unknown>> = {
  workspaces: () => {
    const ws = live<RawWorkspace[]>("workspace.list", {})
    const agents = data().agents as Read<RawAgent[] | undefined>
    const notifications = data().notifications as Read<RawNotification[] | undefined>
    return computed(() => {
      const list = ws()
      return list === undefined ? undefined : classicWorkspaces(list, agents() ?? [], notifications() ?? [])
    })
  },
  agents: () => live("agent.list", {}),
  notifications: () => live("notification.list", {}),
  workspaceCount: () => {
    const ws = data().workspaces as Read<unknown[] | undefined>
    return computed(() => (ws() ?? []).length)
  },
  selectedId: () => {
    const ws = data().workspaces as Read<Array<{ id: string; selected?: boolean }> | undefined>
    return computed(() => (ws() ?? []).find((w) => w.selected)?.id ?? null)
  },
  selectedTitle: () => {
    const ws = data().workspaces as Read<Array<{ title?: string; selected?: boolean }> | undefined>
    return computed(() => (ws() ?? []).find((w) => w.selected)?.title ?? "")
  },
  unreadTotal: () => {
    const ns = data().notifications as Read<Array<{ read?: boolean }> | undefined>
    return computed(() => (ns() ?? []).filter((n) => !n.read).length)
  }
}

let cache: Record<string, Read<unknown>> | null = null
const data = (): Record<string, Read<unknown>> =>
  (cache ??= new Proxy({} as Record<string, Read<unknown>>, {
    get(target, key) {
      if (typeof key !== "string") return undefined
      if (!(key in target)) {
        const make = definitions[key]
        if (!make) return () => undefined
        target[key] = make()
      }
      return target[key]
    }
  }))

/** Old action names that changed in cmux-next. */
const renamedActions: Record<string, string> = { "workspace.select": "workspace.focus", "surface.focus": "tab.focus" }

export function installCompat(g: Record<string, unknown>): void {
  Object.defineProperty(g, "data", { configurable: true, get: data })
  g.sidebar = (render: (ctx: unknown) => unknown) => {
    const exports = ((g.__cmuxAppExports as Record<string, unknown> | undefined) ??= {})
    exports.sidebar = render
  }
  g.openURL = (url: string) => call("action.run", { id: "openBrowser", args: { url } }).catch((e) => log("error", `openURL: ${String(e)}`))
  g.log = (message: unknown) => log("info", message)
  // `cmux(method, params)` from old sidebars: the call form of the global.
  const cmuxObject = g.cmux
  const legacy = (method: string, params: Record<string, unknown> = {}) => {
    const name = renamedActions[method] ?? method
    return call(name, params).catch((e) => log("error", `${method}: ${String(e)}`))
  }
  g.cmux = new Proxy(legacy, {
    get: (_t, key) => (cmuxObject as Record<string | symbol, unknown>)[key]
  })
}
