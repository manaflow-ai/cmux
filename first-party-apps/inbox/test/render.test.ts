import { describe, expect, test } from "bun:test"
import { command, inboxHost, nodeWith, rows, texts, walk } from "./host.ts"

const section = { contribution: "cmux/inbox#inbox", surface: "sidebarSection" }
const feedCalls = (host: ReturnType<typeof inboxHost>["host"]) => host.calls.filter((c) => c.name.startsWith("feed.") || c.name === "action.run")

describe("grouped variant", () => {
  test("renders the owner's groups and order; a click opens the target and marks it seen", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "grouped" } })
    expect(host.mount("m", "renderInbox", section)).toBe("")
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "feed.list")!.params).toEqual({ filter: { status: ["open"] }, groupBy: "source", limit: 100 })
    expect(texts(host, "m").slice(0, 3)).toEqual(["All", "8", "Agents"])
    expect(rows(host, "m")).toEqual([
      "Which retry strategy should the webhook sender use?",
      "Run npm install --save chart-kit?",
      "Sign in to the staging dashboard",
      "Finished: dark mode toggle",
      "Add idempotency keys to refunds",
      "Checks failing: Retry webhook delivery with backoff",
      "Name for the backup volume?",
      "Deploying web-dashboard preview",
      "Disk space low"
    ])
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["GitHub", "Runs", "Apps", "1 snoozed"]))
    const before = host.calls.length
    host.dispatch("m", nodeWith(host, "m", "Row", "Finished: dark mode toggle")!, "tap")
    // The open target runs synchronously in the tap (the user's turn).
    expect(host.calls[before]).toMatchObject({ name: "action.run", params: { id: "tab.show", args: { tab: "tab_2" } } })
    await host.settle(20)
    expect(owner.get("feed_07")!.seenAt).not.toBeNull()
    expect(walk(host, "m").find((n) => n.type === "Row" && n.props.title === "Finished: dark mode toggle")!.props.unread).toBe(false)
  })

  test("the row menu answers a request; the owner's change removes it", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const row = walk(host, "m").find((n) => n.type === "Row" && n.props.title === "Run npm install --save chart-kit?")!
    const menu = row.props.menu as Array<{ title: string; children?: Array<{ title: string }> }>
    expect(menu.map((m) => m.title)).toEqual(["Open", "Respond", "Mark as Done", "Snooze", "Mark as Seen"])
    expect(menu[1]!.children!.map((c) => c.title)).toEqual(["Approve", "Deny"])
    const before = host.calls.length
    host.dispatch("m", row.id, "menu", { path: [1, 0] })
    expect(host.calls[before]).toMatchObject({ name: "feed.respond", params: { item: "feed_02", value: { approved: true } } })
    await host.settle(20)
    expect(owner.responses).toEqual([{ item: "feed_02", value: { approved: true } }])
    expect(rows(host, "m")).not.toContain("Run npm install --save chart-kit?")
  })

  test("snooze goes to the owner (which fires the wake-up); the app arms no timer", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const timersBefore = host.timers.size
    const row = walk(host, "m").find((n) => n.type === "Row" && n.props.title === "Disk space low")!
    const titles = (row.props.menu as Array<{ title: string }>).map((m) => m.title)
    expect(titles).toEqual(["Mark as Done", "Snooze"])
    host.dispatch("m", row.id, "menu", { path: [1, 0] })
    await host.settle(20)
    const call = host.calls.find((c) => c.name === "feed.snooze")!
    expect(call.params.item).toBe("feed_09")
    expect(Date.parse(call.params.until) - Date.now()).toBeGreaterThan(29 * 60_000)
    expect(owner.get("feed_09")!.status).toBe("snoozed")
    expect(rows(host, "m")).not.toContain("Disk space low")
    expect(texts(host, "m")).toContain("2 snoozed")
    expect([...host.timers.values()].filter((t) => t.ms > 60_000)).toHaveLength(0)
    expect(host.timers.size).toBeLessThanOrEqual(timersBefore + 1) // only the notice auto-dismiss, if any
  })

  test("filters and grouping are passed to the owner, never applied locally", async () => {
    const { host, storage } = inboxHost({ settings: { variant: "grouped", groupBy: "workspace" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["api-server", "web-dashboard", "Other"]))
    const filterMenu = walk(host, "m").find((n) => n.type === "Menu" && n.props.title === "All")!
    const titles = (filterMenu.props.menu as Array<{ title?: string }>).map((m) => m.title)
    host.dispatch("m", filterMenu.id, "menu", { path: [titles.indexOf("Show Only What Needs a Response")] })
    await host.settle(20)
    expect(host.calls.filter((c) => c.name === "feed.list").at(-1)!.params).toEqual({ filter: { status: ["open"], needsResponse: true }, groupBy: "workspace", limit: 100 })
    expect(rows(host, "m")).toHaveLength(5)
    expect((storage.get("view") as { filters: { needsResponseOnly: boolean } }).filters.needsResponseOnly).toBe(true)
  })

  test("empty feed and a cmux without a feed owner", async () => {
    const empty = inboxHost({ empty: true }).host
    empty.mount("m", "renderInbox", section)
    await empty.settle(20)
    expect(walk(empty, "m").find((n) => n.type === "EmptyState")!.props.title).toBe("Nothing needs you")
    const missing = inboxHost({ unavailable: true }).host
    missing.mount("m", "renderInbox", section)
    await missing.settle(20)
    expect(walk(missing, "m").find((n) => n.type === "EmptyState")!.props.title).toBe("The feed is not available yet")
  })
})

describe("focus variant", () => {
  test("a click selects; the detail shows the request's response form", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "feed.list")!.params).toEqual({ filter: { status: ["open"] }, limit: 100 })
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["Exponential backoff", "Fixed 30 s delay", "Move failures to a retry queue", "Open", "Done", "Snooze"]))
    host.dispatch("m", nodeWith(host, "m", "Button", "Fixed 30 s delay")!, "tap")
    await host.settle(20)
    expect(owner.responses).toEqual([{ item: "feed_01", value: { choice: "fixed" } }])
    // The answered request left the list; the selection moved on to the approval.
    expect(walk(host, "m").find((n) => n.type === "Row" && n.props.selected === true)!.props.title).toBe("Run npm install --save chart-kit?")
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["Approve", "Deny"]))
    expect(feedCalls(host).some((c) => c.name === "action.run")).toBe(false)
  })

  test("a text request submits the typed answer", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    host.dispatch("m", nodeWith(host, "m", "Row", "Name for the backup volume?")!, "tap")
    await host.settle(20)
    const field = walk(host, "m").find((n) => n.type === "TextField")!
    expect(field.props.placeholder).toBe("volume name")
    host.dispatch("m", field.id, "submit", { text: " backups-02 " })
    await host.settle(20)
    expect(owner.responses).toEqual([{ item: "feed_04", value: { text: "backups-02" } }])
  })

  test("a sign-in request opens the agent's browser tab next to this one", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    host.dispatch("m", nodeWith(host, "m", "Row", "Sign in to the staging dashboard")!, "tap")
    await host.settle(20)
    const before = host.calls.length
    host.dispatch("m", nodeWith(host, "m", "Button", "Continue in Browser")!, "tap")
    expect(host.calls[before]).toMatchObject({ name: "action.run", params: { id: "browser.duplicateRight", args: { browser: "browser_1" } } })
    await host.settle(20)
    // Opening is not an answer: the agent resumes when the owner sees the sign-in finish.
    expect(owner.responses).toEqual([])
    expect(owner.get("feed_03")!.status).toBe("open")
  })
})

describe("card variant", () => {
  test("one item at a time; Skip moves on, Done finishes through the owner", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "card" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["1 of 9", "Which retry strategy should the webhook sender use?", "Skip"]))
    host.dispatch("m", nodeWith(host, "m", "Button", "Skip")!, "tap")
    await host.settle(10)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["2 of 9", "Run npm install --save chart-kit?", "Approve", "Deny"]))
    host.dispatch("m", nodeWith(host, "m", "Button", "Done")!, "tap")
    await host.settle(20)
    expect(owner.get("feed_02")!.status).toBe("done")
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["2 of 8", "Sign in to the staging dashboard"]))
  })

  test("the variant command cycles and stores the override when settings are read-only", async () => {
    const { host, storage } = inboxHost({ settings: { variant: "card" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(await command(host, "cycleVariant")).toEqual({ ok: true, body: { value: { variant: "grouped" } } })
    await host.settle(20)
    expect(storage.get("variantOverride")).toEqual({ variant: "grouped", base: "card" })
    expect(texts(host, "m")).toContain("Agents")
  })
})

describe("status item and commands", () => {
  test("the badge shows the owner's counts and follows feed.changed without re-listing everything", async () => {
    const { host } = inboxHost()
    host.mount("s", "renderStatus", { contribution: "cmux/inbox#badge", surface: "statusItem" })
    await host.settle(20)
    expect(walk(host, "s").find((n) => n.type === "Badge")!.props).toMatchObject({ text: "8", tone: "warning" })
    expect(host.calls.find((c) => c.name === "feed.list")!.params).toEqual({ filter: { status: ["open"] }, limit: 8 })
    host.emit("feed.changed", { revision: "9", changed: ["feed_01"], counts: { unseen: 3, open: 9, needsResponse: 0, urgent: 1, snoozed: 1 } })
    await host.settle(20)
    expect(walk(host, "s").find((n) => n.type === "Badge")!.props).toMatchObject({ text: "3", tone: "secondary" })
    const menu = walk(host, "s")[0]!.props.menu as Array<{ title: string }>
    expect(menu[0]!.title).toBe("Choose: Which retry strategy should the webhook sender use?")
  })

  test("list, markDone and snooze work with nothing mounted (MCP tools); there is no respond tool", async () => {
    const { host, owner } = inboxHost()
    const listed = await command(host, "list", { needsResponse: true })
    expect(listed.ok).toBe(true)
    const value = listed.body.value as { items: Array<{ id: string; request_kind: string }> }
    expect(value.items.map((i) => i.request_kind)).toEqual(["choice", "approve", "sign-in", "input", "review"])
    expect(await command(host, "markDone", { id: "feed_05" })).toEqual({ ok: true, body: { value: { id: "feed_05", done: true } } })
    expect(owner.get("feed_05")!.status).toBe("done")
    const snoozed = await command(host, "snooze", { id: "feed_07", minutes: 90 })
    expect(snoozed.ok).toBe(true)
    expect(owner.get("feed_07")!.status).toBe("snoozed")
    const missing = await command(host, "markDone", { id: "feed_nope" })
    expect(missing).toMatchObject({ ok: false, body: { code: "item.not_found" } })
    expect((await command(host, "respond", { id: "feed_01", value: "x" })).body.code).toBe("export.missing")
  })

  test("next item selects and opens in the owner's order; mark all seen is one owner call", async () => {
    const { host, owner } = inboxHost()
    expect((await command(host, "nextItem")).body.value).toEqual({ id: "feed_01" })
    expect((await command(host, "nextItem", { open: false })).body.value).toEqual({ id: "feed_02" })
    expect(host.calls.filter((c) => c.name === "action.run")).toHaveLength(1)
    const r = await command(host, "markAllSeen")
    expect(r.body.value).toEqual({ marked: 7 })
    expect(host.calls.filter((c) => c.name === "feed.mark").at(-1)!.params).toEqual({ filter: { status: ["open"], unseen: true }, state: "seen" })
    expect(owner.counts().unseen).toBe(0)
  })

  test("the app stores only view preferences, never item state", async () => {
    const { host, storage } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    await command(host, "markDone", {})
    await command(host, "snooze", {})
    for (const key of storage.keys()) expect(["view", "variantOverride"]).toContain(key)
  })
})
