// Compatibility layer for old cmux JS custom sidebars (~/.config/cmux/sidebars/*.js):
// `sidebar(fn)`, `data.<key>()`, `cmux(method, params)`, `openURL(url)`, `log()`.
// `cmux app import-sidebar` wraps such a file into a `local/<name>` app whose
// `sidebars` contribution renders the export `sidebar`.

import { call, live, log } from "./cmux.ts"
import { computed, type Read } from "./reactive.ts"

/** Old data keys mapped onto live catalog reads. Created on first use so unused keys cost nothing. */
const definitions: Record<string, () => Read<unknown>> = {
  workspaces: () => live("workspace.list", {}),
  agents: () => live("agent.list", {}),
  notifications: () => live("notification.list", {}),
  workspaceCount: () => {
    const ws = data().workspaces as Read<unknown[] | undefined>
    return computed(() => (ws() ?? []).length)
  },
  selectedId: () => {
    const ws = data().workspaces as Read<Array<{ id: string; focused?: boolean }> | undefined>
    return computed(() => (ws() ?? []).find((w) => w.focused)?.id ?? null)
  },
  selectedTitle: () => {
    const ws = data().workspaces as Read<Array<{ name?: string; focused?: boolean }> | undefined>
    return computed(() => (ws() ?? []).find((w) => w.focused)?.name ?? "")
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
