// Invented, neutral fixture data shared by the tests and the preview harness.
// `bun first-party-apps/inbox/test/fixtures.ts --write` regenerates
// preview/*.json with timestamps relative to now (ages read naturally in
// screenshots).
import { writeFileSync } from "node:fs"
import { join } from "node:path"

const MIN = 60_000
const ago = (now: number, minutes: number) => String(now - minutes * MIN)
const iso = (now: number, minutes: number) => new Date(now - minutes * MIN).toISOString()

export function sessionData(now: number) {
  const workspaces = [
    { id: "workspace_1", session_id: "session_1", name: "api-server", index: 0, focused: true },
    { id: "workspace_2", session_id: "session_1", name: "web-dashboard", index: 1, focused: false }
  ]
  const screens = [
    { id: "screen_1", workspace_id: "workspace_1", name: null, index: 0, focused: true, layout: {} },
    { id: "screen_2", workspace_id: "workspace_2", name: null, index: 0, focused: false, layout: {} }
  ]
  const panes = [
    { id: "pane_1", screen_id: "screen_1", name: null, focused: true, zoomed: false },
    { id: "pane_2", screen_id: "screen_2", name: null, focused: false, zoomed: false }
  ]
  const tabs = [
    { id: "tab_1", pane_id: "pane_1", name: null, index: 0, focused: true, content_kind: "terminal", content_id: "terminal_1" },
    { id: "tab_2", pane_id: "pane_2", name: null, index: 0, focused: false, content_kind: "terminal", content_id: "terminal_2" },
    { id: "tab_3", pane_id: "pane_1", name: null, index: 1, focused: false, content_kind: "terminal", content_id: "terminal_3" },
    { id: "tab_4", pane_id: "pane_2", name: null, index: 1, focused: false, content_kind: "terminal", content_id: "terminal_4" }
  ]
  const terminal = (id: string, tab: string, title: string, cwd: string) => ({ id, tab_id: tab, tab_ids: [tab], title, cwd, cols: 120, rows: 40, running: true, lifecycle: "running" })
  const terminals = [
    terminal("terminal_1", "tab_1", "fix flaky retry test", "~/src/api-server"),
    terminal("terminal_2", "tab_2", "dark mode toggle", "~/src/web-dashboard"),
    terminal("terminal_3", "tab_3", "docs build", "~/src/api-server/docs"),
    terminal("terminal_4", "tab_4", "refactor charts", "~/src/web-dashboard")
  ]
  const agent = (id: string, term: string, state: string, kind: string, minutes: number) => ({
    id,
    session_id: "session_1",
    terminal_id: term,
    state,
    source: "hook",
    updated_at_ms: ago(now, minutes),
    source_session: kind
  })
  const agents = [agent("agent_1", "terminal_1", "blocked", "claude", 2), agent("agent_2", "terminal_2", "done", "codex", 14), agent("agent_3", "terminal_4", "working", "claude", 1)]
  const note = (id: string, title: string, body: string, level: string, minutes: number, extra: Record<string, unknown> = {}) => ({
    id,
    session_id: "session_1",
    title,
    body,
    level,
    created_at_ms: ago(now, minutes),
    unread: true,
    read_by: [],
    ...extra
  })
  const notifications = [
    note("notification_1", "Permission needed", "Run npm test -- --runInBand?", "warning", 2, { terminal_id: "terminal_1", subtitle: "Allow running the test suite" }),
    note("notification_2", "Docs build failed", "2 broken links in guides/retries.md", "error", 25, { terminal_id: "terminal_3" }),
    note("notification_3", "Disk space low", "Less than 5 GB free on the build volume", "warning", 180),
    note("notification_4", "Preview deployed", "web-dashboard preview is ready", "info", 26 * 60, { unread: false })
  ]
  const screen = { text: "Claude wants to run:\n  npm test -- --runInBand\n\n  1. Yes\n  2. Yes, and don't ask again for npm test\n  3. No, and tell Claude what to do differently\n", cols: 120, rows: 40, cursor_row: 6, cursor_col: 0, cursor_visible: true }
  return { workspaces, screens, panes, tabs, terminals, agents, notifications, screen }
}

const search = (now: number, items: Array<[string, number, string, string, number, boolean?]>) => ({
  total_count: items.length,
  items: items.map(([repo, number, title, author, minutes, draft]) => ({
    number,
    title,
    html_url: `https://github.com/${repo}/pull/${number}`,
    repository_url: `https://api.github.com/repos/${repo}`,
    updated_at: iso(now, minutes),
    draft: !!draft,
    user: { login: author },
    pull_request: {}
  }))
})

export function githubData(now: number) {
  return {
    review: search(now, [["example-org/payments", 412, "Add idempotency keys to refunds", "river", 40]]),
    failing: search(now, [["example-org/api-server", 88, "Retry webhook delivery with backoff", "me", 70]]),
    mention: search(now, [["example-org/design-system", 1203, "Button focus ring contrast", "sam", 300]]),
    pull: { number: 88, head: { sha: "4f2a9c1" } },
    checks: {
      total_count: 4,
      check_runs: [
        { name: "unit tests", status: "completed", conclusion: "failure" },
        { name: "lint", status: "completed", conclusion: "success" },
        { name: "integration", status: "completed", conclusion: "failure" },
        { name: "build", status: "completed", conclusion: "success" }
      ]
    }
  }
}

/** A preview-harness fixture: every op the app reads, answered from the data above. */
export function previewFixture(now: number, options: { github?: "ok" | "notGranted" | "unavailable"; empty?: boolean } = {}) {
  const s = sessionData(now)
  const g = githubData(now)
  const github = options.github ?? "ok"
  const ops: Record<string, unknown> = {
    "notification.list": options.empty ? [] : s.notifications,
    "agent.list": options.empty ? [] : s.agents,
    "terminal.list": s.terminals,
    "workspace.list": s.workspaces,
    "screen.list": s.screens,
    "pane.list": s.panes,
    "tab.list": s.tabs,
    "terminal.screen.read": s.screen,
    "app.storage.get": null,
    "app.storage.set": {},
    "integration.request":
      github === "ok" && !options.empty
        ? { $sequence: [g.review, g.failing, g.mention, g.pull, g.checks] }
        : github === "unavailable"
          ? { $error: { code: "operation.unsupported", message: "integration.request is not supported by this host yet" } }
          : options.empty
            ? { $sequence: [{ items: [] }, { items: [] }, { items: [] }] }
            : { $error: { code: "scope.missing", message: "this app does not hold integration:github:read" } }
  }
  const grant = ["notification:read", "notification:write", "agent:read", "terminal:read", "workspace:read", "workspace:write", "actions:run", "terminal:execute"]
  if (github !== "notGranted") grant.push("integration:github:read")
  return { grant, ops }
}

if (import.meta.main && process.argv.includes("--write")) {
  const dir = join(import.meta.dir, "../preview")
  const now = Date.now()
  const write = (name: string, value: unknown) => writeFileSync(join(dir, `${name}.json`), `${JSON.stringify(value, null, 2)}\n`)
  for (const variant of ["grouped", "focus", "card"]) write(variant, previewFixture(now))
  write("empty", previewFixture(now, { empty: true }))
  write("github-not-granted", previewFixture(now, { github: "notGranted" }))
  write("github-unavailable", previewFixture(now, { github: "unavailable" }))
  console.log(`wrote ${dir}`)
}
