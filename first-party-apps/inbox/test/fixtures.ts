// Invented, neutral feed items in the owner's wire shape, shared by the tests
// and the preview harness. `bun first-party-apps/inbox/test/fixtures.ts --write`
// regenerates preview/*.json from the mock owner, with times relative to now
// (ages read naturally in screenshots).
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import type { FeedItem, GroupBy } from "../src/feed.ts"
import { MockFeed } from "./mock-feed.ts"

const MIN = 60_000

/** `fi_` + 20 characters, like the owner's ids. */
export const fid = (name: string) => `fi_${name.padEnd(20, "0").slice(0, 20)}`

const agent = (label: string, n: number) => ({ kind: "agent" as const, scope: `inst:install_mac/agent:agent_${n}`, label, install: "install_mac", agent: `agent_${n}` })
const claude = agent("Claude", 1)
const codex = agent("Codex", 2)
const github = { kind: "integration" as const, scope: "conn_github", label: "GitHub" }
const backup = { kind: "automation" as const, scope: "run_backup", label: "nightly-backup" }
const deploy = { kind: "automation" as const, scope: "run_deploy", label: "preview-deploy" }
const disk = { kind: "app" as const, scope: "app:example/disk-monitor", label: "Disk Monitor" }

export function feedItems(now: number): FeedItem[] {
  let order = 0
  const item = (name: string, minutes: number, over: Partial<FeedItem> & Pick<FeedItem, "type" | "kind" | "title" | "poster">): FeedItem => {
    const at = now - minutes * MIN
    return {
      id: fid(name),
      home: "cloud",
      body: "",
      priority: "normal",
      dedupe_key: null,
      thread: null,
      context: {},
      attachments: [],
      actions: [],
      open: null,
      state: "open",
      answer: null,
      cancel: null,
      needs_mac: false,
      expires_at: now + 24 * 60 * MIN,
      read_at: null,
      seen_at: null,
      archived_at: null,
      snoozed_until: null,
      count: 1,
      order: 0,
      revision: 1,
      created_at: at,
      updated_at: at,
      closed_at: null,
      ...over
    }
  }
  const items = [
    item("retrychoice", 2, {
      type: "request",
      kind: "choice",
      title: "Which retry strategy should the webhook sender use?",
      body: "Deliveries fail about 2% of the time. Retrying in place blocks the queue.",
      priority: "high",
      poster: claude,
      thread: "session_14",
      context: { workspace: "workspace_1", tab: "tab_1", terminal: "terminal_1" },
      open: { action: "tab.focus", args: { tab: "tab_1" } },
      prompt: {
        questions: [
          {
            id: "strategy",
            question: "Which retry strategy?",
            multi: false,
            allow_other: false,
            options: [
              { id: "exponential", label: "Exponential backoff" },
              { id: "fixed", label: "Fixed 30 s delay" },
              { id: "queue", label: "Move failures to a retry queue" }
            ]
          }
        ]
      }
    }),
    item("npminstall", 5, {
      type: "request",
      kind: "approve",
      title: "Run npm install --save chart-kit?",
      priority: "high",
      poster: codex,
      thread: "session_3",
      context: { workspace: "workspace_2", tab: "tab_2", terminal: "terminal_2" },
      open: { action: "tab.focus", args: { tab: "tab_2" } },
      prompt: { action: { type: "command", summary: "Install a charting package", command: "npm install --save chart-kit", cwd: "~/web-dashboard" }, scopes: ["once", "session"] }
    }),
    item("signin", 9, {
      type: "request",
      kind: "sign-in",
      title: "Sign in to the staging dashboard",
      priority: "high",
      poster: claude,
      needs_mac: true,
      thread: "session_14",
      context: { workspace: "workspace_1", browser_tab: "browser_1" },
      open: { action: "browser.duplicateRight", args: { browser_tab: "browser_1" } },
      prompt: { origin: "https://staging.example.com", url: "https://staging.example.com/login", browser_tab: "browser_1", reason: "Read the deploy logs" }
    }),
    item("volumename", 20, {
      type: "request",
      kind: "input",
      title: "Name for the backup volume?",
      priority: "high",
      poster: backup,
      prompt: { schema: { type: "object", properties: { volume: { type: "string", title: "Volume name" } }, required: ["volume"] } }
    }),
    item("dropdbs", 25, {
      type: "request",
      kind: "confirm",
      title: "Delete 4 stale preview databases?",
      poster: deploy,
      context: { workspace: "workspace_2" },
      prompt: { statement: "They belong to closed pull requests and have no traffic for 14 days.", confirm_label: "Delete", destructive: true }
    }),
    item("refunds", 40, {
      type: "request",
      kind: "review",
      title: "Add idempotency keys to refunds",
      body: "example-org/payments #412 · requested by river",
      poster: github,
      thread: "pr:example-org/payments#412",
      context: { url: "https://github.com/example-org/payments/pull/412" },
      open: { action: "url.open", args: { url: "https://github.com/example-org/payments/pull/412" } },
      prompt: { subject: "pr", ref: "https://github.com/example-org/payments/pull/412" }
    }),
    item("checksfail", 70, {
      type: "notice",
      kind: "notice",
      title: "Checks failing: Retry webhook delivery with backoff",
      body: "example-org/api-server #88 · 2 failed: unit tests, integration",
      priority: "high",
      poster: github,
      thread: "pr:example-org/api-server#88",
      context: { url: "https://github.com/example-org/api-server/pull/88" },
      open: { action: "url.open", args: { url: "https://github.com/example-org/api-server/pull/88" } },
      actions: [{ id: "checks", label: "View Checks" }]
    }),
    item("darkmode", 14, {
      type: "notice",
      kind: "notice",
      title: "Finished: dark mode toggle",
      body: "Added the toggle to settings and updated 3 tests.",
      poster: codex,
      thread: "session_3",
      context: { workspace: "workspace_2", tab: "tab_2", terminal: "terminal_2" },
      open: { action: "tab.focus", args: { tab: "tab_2" } }
    }),
    item("previewup", 3, {
      type: "notice",
      kind: "notice",
      title: "Preview deployed",
      body: "web-dashboard, 3 pages changed",
      priority: "low",
      poster: deploy,
      context: { workspace: "workspace_2" },
      count: 2
    }),
    item("diskspace", 180, { type: "notice", kind: "notice", title: "Disk space low", body: "Less than 5 GB free on the build volume", poster: disk, read_at: now - 100 * MIN }),
    item("releasenotes", 300, { type: "notice", kind: "notice", title: "Release notes draft ready", poster: claude, snoozed_until: now + 3 * 60 * MIN }),
    item("backupdone", 600, { type: "notice", kind: "notice", title: "Nightly backup finished", poster: backup, read_at: now - 500 * MIN, archived_at: now - 400 * MIN })
  ]
  // The owner's order is the post order: older items first.
  for (const i of [...items].sort((a, b) => a.created_at - b.created_at)) i.order = ++order
  return items
}

export const WORKSPACES = [
  { id: "workspace_1", session_id: "session_1", name: "api-server", index: 0, focused: true },
  { id: "workspace_2", session_id: "session_1", name: "web-dashboard", index: 1, focused: false }
]

/** A preview-harness fixture answered by the mock owner (static: the harness does not filter). */
export function previewFixture(now: number, options: { groupBy?: GroupBy; empty?: boolean; unavailable?: boolean; done?: boolean } = {}) {
  const owner = new MockFeed(options.empty ? [] : feedItems(now), () => now)
  const list = owner.list(options.done ? { state: "all", archived: true, order: "recent", limit: 100 } : { state: "open", order: "urgent", ...(options.groupBy ? { group_by: options.groupBy } : {}), limit: 100 })
  const unsupported = { $error: { code: "operation.unsupported", message: "feed.list is not supported by this host yet" } }
  const ops: Record<string, unknown> = options.unavailable
    ? { "feed.list": unsupported, "feed.counts": unsupported }
    : {
        "feed.list": list,
        "feed.counts": owner.counts(),
        "feed.read": { items: [] },
        "feed.archive": { items: [] },
        "feed.snooze": { items: [] },
        "feed.answer": { item: list.items[0] ?? null },
        "feed.cancel": { item: list.items[0] ?? null }
      }
  Object.assign(ops, { "action.run": null, "workspace.list": WORKSPACES, "app.storage.get": null, "app.storage.set": {} })
  // The preview engine's bundled scope table predates the feed ops: name their scopes (generated/scopes.json).
  const scope = (name: string, cls: string) => ({ scope: name, class: cls })
  const scopes = Object.fromEntries([
    ...["feed.list", "feed.get", "feed.counts"].map((op) => [op, scope("feed:read", "read")]),
    ...["feed.read", "feed.archive", "feed.unarchive", "feed.snooze", "feed.answer", "feed.cancel"].map((op) => [op, scope("feed:write", "mutation")])
  ])
  return { grant: ["feed:read", "feed:write", "actions:run", "workspace:read"], scopes, ops }
}

if (import.meta.main && process.argv.includes("--write")) {
  const dir = join(import.meta.dir, "../preview")
  const now = Date.now()
  const write = (name: string, value: unknown) => writeFileSync(join(dir, `${name}.json`), `${JSON.stringify(value, null, 2)}\n`)
  write("grouped", previewFixture(now, { groupBy: "poster" }))
  write("grouped-workspace", previewFixture(now, { groupBy: "workspace" }))
  write("focus", previewFixture(now))
  write("card", previewFixture(now))
  write("done", previewFixture(now, { done: true }))
  write("empty", previewFixture(now, { empty: true }))
  write("unavailable", previewFixture(now, { unavailable: true }))
  console.log(`wrote ${dir}`)
}
