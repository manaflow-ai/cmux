// Draws the packed widget in the fake host at a fixed instant with a fake project index and returns
// the scene ops it sends, for the tests and the gallery fixtures (preview/build.ts).
// The instant: Tuesday, November 17, 2026, 1:12 PM in Los Angeles.
import { FakeHost, type Op } from "cmux-extension-sdk/testing"

export const AT = Date.UTC(2026, 10, 17, 21, 12, 0)

export type Index = "busy" | "few" | "empty" | "denied" | "hiddenAndMissing"

export interface Render {
  size: "small" | "medium" | "large"
  index: Index
  place?: "newtab" | "sidebar"
  machine?: string | null
}

const MINUTE = 60_000
const project = (name: string, path: string, minutesAgo: number, overlay: Record<string, unknown> = {}, state = "present") => ({
  path,
  name,
  last_used_ms: String(AT - minutesAgo * MINUTE),
  sources: { cmux: { first_seen_ms: String(AT - 90 * 24 * 60 * MINUTE), last_used_ms: String(AT - minutesAgo * MINUTE) } },
  overlay,
  state
})

const BUSY = [
  project("website", "/Users/leo/code/website", 25),
  project("cmux", "/Users/leo/code/cmux", 2),
  project("api", "/Users/leo/code/api", 3 * 60),
  project("dotfiles", "/Users/leo/dotfiles", 26 * 60),
  project("notes", "/Users/leo/notes", 3 * 24 * 60, { rename: "Notes" }),
  project("ios-app", "/Users/leo/code/ios-app", 5 * 24 * 60),
  project("design-system", "/Users/leo/code/design-system", 9 * 24 * 60),
  project("blog", "/Users/leo/code/blog", 20 * 24 * 60),
  project("old-prototype", "/Users/leo/code/old-prototype", 60 * 24 * 60),
  project("manaflow", "/Users/leo/code/manaflow", 40 * 24 * 60, { pinned: true, order: 0 })
]

/** Each project index the gallery shows, as the daemon would answer project.list. */
export const INDEXES: Record<Index, { projects: unknown[] } | { error: string }> = {
  busy: { projects: BUSY },
  few: { projects: BUSY.slice(0, 3) },
  empty: { projects: [] },
  denied: { error: "scope.missing" },
  hiddenAndMissing: {
    projects: [
      project("secret", "/Users/leo/code/secret", 1, { hidden: true }),
      project("gone", "/Users/leo/code/gone", 1, {}, "missing"),
      project("cmux", "/Users/leo/code/cmux", 2)
    ]
  }
}

export async function renderScene(source: string, render: Render): Promise<{ ops: Op[]; host: FakeHost; calls: Array<[string, unknown]> }> {
  const host = new FakeHost("", { app: { id: "cmux/projects", version: "1.0.0", locale: "en-US" }, apiVersion: "1.0.0", settings: {} })
  const calls: Array<[string, unknown]> = []
  const answer = INDEXES[render.index]
  const machine = render.machine === undefined ? "Leo's MacBook Pro" : render.machine
  host.handlers = {
    "project.list": (params: unknown) => {
      calls.push(["project.list", params])
      return "error" in answer
        ? { ok: false, body: { code: answer.error, message: "refused", retryable: false } }
        : { ok: true, body: { value: { projects: answer.projects, sources: [] } } }
    },
    "machine.get": (params: unknown) => {
      calls.push(["machine.get", params])
      return machine === null
        ? { ok: false, body: { code: "scope.missing", message: "refused", retryable: false } }
        : { ok: true, body: { value: { id: "machine_leo", name: machine, origin: "local", status: "running" } } }
    },
    "workspace.create": (params: unknown) => {
      calls.push(["workspace.create", params])
      return { ok: true, body: { value: { workspace: "workspace_1" }, revision: "1", replayed: false } }
    }
  }
  host.eval(`Date.now = () => ${AT}`)
  host.eval(source)
  host.mount("w", "renderProjects", {
    surface: "widget",
    size: render.size,
    place: render.place ?? "newtab",
    instance: `preview-${render.size}`,
    settings: {},
    locale: "en-US",
    timeZone: "America/Los_Angeles",
    now: undefined
  })
  await host.settle()
  return { ops: host.batches("w").flat(), host, calls }
}
/** The nodes on screen after every batch, in tree order (a re-render removes and recreates nodes). */
export function visible(ops: Op[]): Op[] {
  const nodes = new Map<string, Op>()
  const children = new Map<string, string[]>()
  const parents = new Set<string>()
  let root: string | undefined
  for (const op of ops) {
    if (op.op === "create") {
      nodes.set(op.id, { ...op, props: { ...(op.props ?? {}) } })
      root ??= op.id
    } else if (op.op === "update") {
      const node = nodes.get(op.id)
      if (node) node.props = { ...(node.props ?? {}), ...(op.props ?? {}) }
    } else if (op.op === "remove") {
      nodes.delete(op.id)
    } else if (op.op === "children") {
      children.set(op.id, op.children ?? [])
      for (const c of op.children ?? []) parents.add(c)
    }
  }
  const out: Op[] = []
  const walk = (id: string) => {
    const node = nodes.get(id)
    if (!node) return
    out.push(node)
    for (const c of children.get(id) ?? []) walk(c)
  }
  if (root) walk(root)
  return out
}
