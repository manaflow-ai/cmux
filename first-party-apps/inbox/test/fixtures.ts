// Invented, neutral feed items shared by the tests and the preview harness.
// `bun first-party-apps/inbox/test/fixtures.ts --write` regenerates
// preview/*.json from the mock owner, with timestamps relative to now (ages
// read naturally in screenshots).
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import type { FeedAction, FeedItem } from "../src/feed.ts"
import { MockFeed } from "./mock-feed.ts"

const MIN = 60_000
const iso = (now: number, minutes: number) => new Date(now - minutes * MIN).toISOString()

const open: FeedAction = { id: "open", title: "Open", kind: "open" }
const done: FeedAction = { id: "done", title: "Done", kind: "done" }
const snooze: FeedAction = { id: "snooze", title: "Snooze", kind: "snooze" }

const agentClaude = { kind: "agent" as const, id: "agent_1", name: "Claude" }
const agentCodex = { kind: "agent" as const, id: "agent_2", name: "Codex" }
const github = { kind: "integration" as const, id: "github", name: "GitHub" }
const api = { workspace: "workspace_1", workspaceName: "api-server" }
const web = { workspace: "workspace_2", workspaceName: "web-dashboard" }

export function feedItems(now: number): FeedItem[] {
  let n = 0
  const item = (minutes: number, over: Partial<FeedItem> & Pick<FeedItem, "kind" | "title" | "source">): FeedItem => ({
    id: `feed_${String(++n).padStart(2, "0")}`,
    urgency: "normal",
    needsResponse: false,
    subject: {},
    status: "open",
    snoozedUntil: null,
    seenAt: null,
    createdAt: iso(now, minutes),
    updatedAt: iso(now, minutes),
    revision: "1",
    expiresAt: null,
    actions: [open, done, snooze],
    ...over
  })
  return [
    item(2, {
      kind: "request",
      requestKind: "choice",
      title: "Which retry strategy should the webhook sender use?",
      body: "Deliveries fail about 2% of the time. Retrying in place blocks the queue.",
      urgency: "high",
      needsResponse: true,
      source: agentClaude,
      subject: { ...api, terminal: "terminal_1", tab: "tab_1", agent: "agent_1" },
      thread: "agent_1:turn_14",
      response: {
        type: "choice",
        options: [
          { value: "exponential", label: "Exponential backoff" },
          { value: "fixed", label: "Fixed 30 s delay" },
          { value: "queue", label: "Move failures to a retry queue" }
        ]
      },
      open: { action: "tab.show", args: { tab: "tab_1" } }
    }),
    item(5, {
      kind: "request",
      requestKind: "approve",
      title: "Run npm install --save chart-kit?",
      body: "npm install --save chart-kit",
      needsResponse: true,
      source: agentCodex,
      subject: { ...web, terminal: "terminal_2", tab: "tab_2", agent: "agent_2" },
      thread: "agent_2:turn_3",
      response: { type: "approve" },
      open: { action: "tab.show", args: { tab: "tab_2" } }
    }),
    item(9, {
      kind: "request",
      requestKind: "sign-in",
      title: "Sign in to the staging dashboard",
      body: "The agent needs a signed-in session to check the deploy logs.",
      needsResponse: true,
      source: agentClaude,
      subject: { ...api, browser: "browser_1", agent: "agent_1" },
      thread: "agent_1:turn_14",
      response: { type: "external" },
      // Proposed action: show the agent's browser tab duplicated to the right.
      open: { action: "browser.duplicateRight", args: { browser: "browser_1" } }
    }),
    item(20, {
      kind: "request",
      requestKind: "input",
      title: "Name for the backup volume?",
      needsResponse: true,
      source: { kind: "run", id: "run_7", name: "nightly-backup" },
      response: { type: "text", placeholder: "volume name" },
      actions: [done, snooze]
    }),
    item(40, {
      kind: "request",
      requestKind: "review",
      title: "Add idempotency keys to refunds",
      body: "example-org/payments #412 · requested by river",
      needsResponse: true,
      source: github,
      subject: { url: "https://github.com/example-org/payments/pull/412" },
      thread: "github:example-org/payments#412",
      open: { action: "openBrowser", args: { url: "https://github.com/example-org/payments/pull/412" } }
    }),
    item(70, {
      kind: "notify",
      title: "Checks failing: Retry webhook delivery with backoff",
      body: "example-org/api-server #88 · 2 failed: unit tests, integration",
      urgency: "high",
      source: github,
      subject: { url: "https://github.com/example-org/api-server/pull/88" },
      thread: "github:example-org/api-server#88",
      open: { action: "openBrowser", args: { url: "https://github.com/example-org/api-server/pull/88" } },
      actions: [open, done, snooze, { id: "rerun", title: "Re-run Failed Checks", kind: "custom", target: { action: "openBrowser", args: { url: "https://github.com/example-org/api-server/pull/88/checks" } } }]
    }),
    item(14, {
      kind: "notify",
      title: "Finished: dark mode toggle",
      body: "Added the toggle to settings and updated 3 tests.",
      source: agentCodex,
      subject: { ...web, terminal: "terminal_2", tab: "tab_2", agent: "agent_2" },
      open: { action: "tab.show", args: { tab: "tab_2" } }
    }),
    item(3, {
      kind: "watch",
      title: "Deploying web-dashboard preview",
      body: "Step 3 of 5: building assets",
      source: { kind: "run", id: "run_8", name: "preview-deploy" },
      subject: web
    }),
    item(180, {
      kind: "notify",
      title: "Disk space low",
      body: "Less than 5 GB free on the build volume",
      source: { kind: "app", id: "cmux/disk-monitor", name: "Disk Monitor" },
      seenAt: iso(now, 100)
    }),
    item(300, {
      kind: "notify",
      title: "Preview deployed",
      source: { kind: "run", id: "run_6", name: "preview-deploy" },
      subject: web,
      status: "snoozed",
      snoozedUntil: new Date(now + 3 * 60 * MIN).toISOString()
    })
  ]
}

/** A preview-harness fixture answered by the mock owner (static: the harness does not re-filter). */
export function previewFixture(now: number, options: { groupBy?: "source" | "workspace" | "thread"; empty?: boolean; unavailable?: boolean } = {}) {
  const owner = new MockFeed(options.empty ? [] : feedItems(now), () => now)
  const list = owner.list({ filter: { status: ["open"] }, groupBy: options.groupBy, limit: 100 })
  const unsupported = { $error: { code: "operation.unsupported", message: "feed.list is not supported by this host yet" } }
  const mutation = { revision: "2" }
  const ops: Record<string, unknown> = options.unavailable
    ? { "feed.list": unsupported, "feed.counts": unsupported }
    : {
        "feed.list": list,
        "feed.counts": owner.counts(),
        "feed.get": list.items[0] ?? null,
        "feed.mark": mutation,
        "feed.snooze": mutation,
        "feed.respond": mutation
      }
  Object.assign(ops, { "action.run": null, "app.storage.get": null, "app.storage.set": {} })
  const op = (scope: string, cls: string) => ({ scope, class: cls })
  return {
    grant: ["feed:read", "feed:write", "actions:run"],
    scopes: {
      "feed.list": op("feed:read", "read"),
      "feed.get": op("feed:read", "read"),
      "feed.counts": op("feed:read", "read"),
      "feed.mark": op("feed:write", "mutation"),
      "feed.snooze": op("feed:write", "mutation"),
      "feed.respond": op("feed:write", "mutation")
    },
    ops
  }
}

if (import.meta.main && process.argv.includes("--write")) {
  const dir = join(import.meta.dir, "../preview")
  const now = Date.now()
  const write = (name: string, value: unknown) => writeFileSync(join(dir, `${name}.json`), `${JSON.stringify(value, null, 2)}\n`)
  write("grouped", previewFixture(now, { groupBy: "source" }))
  write("grouped-workspace", previewFixture(now, { groupBy: "workspace" }))
  write("focus", previewFixture(now))
  write("card", previewFixture(now))
  write("empty", previewFixture(now, { empty: true }))
  write("unavailable", previewFixture(now, { unavailable: true }))
  console.log(`wrote ${dir}`)
}
