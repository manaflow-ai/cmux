import { describe, expect, test } from "bun:test"
import { command, fireTimers, inboxHost, nodeWith, rows, texts, walk } from "./host.ts"

const section = { contribution: "cmux/inbox#inbox", surface: "sidebarSection" }

describe("grouped variant", () => {
  test("rows under source headers; a click opens the agent's tab and marks it read", async () => {
    const { host, storage } = inboxHost({ settings: { variant: "grouped" } })
    expect(host.mount("m", "renderInbox", section)).toBe("")
    await host.settle(20)
    expect(texts(host, "m").slice(0, 6)).toEqual(["All", "4", "Agents", "2", "Claude", "Codex"])
    expect(rows(host, "m")).toEqual([
      "Claude",
      "Codex",
      "Docs build failed",
      "Disk space low",
      "Preview deployed",
      "Retry webhook delivery with backoff",
      "Add idempotency keys to refunds",
      "Button focus ring contrast"
    ])
    const before = host.calls.length
    host.dispatch("m", nodeWith(host, "m", "Row", "Claude")!, "tap")
    // The focus call is issued synchronously by the tap (it runs in the user's turn).
    expect(host.calls[before]!.name).toBe("tab.focus")
    await host.settle(10)
    expect(host.calls.find((c) => c.name === "tab.focus")!.params).toEqual({ tab: "tab_1" })
    expect(host.calls.find((c) => c.name === "notification.ack")!.params).toEqual({ client_id: "app:cmux/inbox", notifications: ["notification_1"] })
    expect((storage.get("ledger") as { seen: Record<string, number> }).seen["agent:agent_1"]).toBeGreaterThan(0)
    const claude = walk(host, "m").find((n) => n.type === "Row" && n.props.title === "Claude")!
    expect(claude.props.unread).toBe(false)
  })

  test("a pull request opens in a browser tab", async () => {
    const { host } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    host.dispatch("m", nodeWith(host, "m", "Row", "Add idempotency keys to refunds")!, "tap")
    await host.settle(5)
    expect(host.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "openBrowser", args: { url: "https://github.com/example-org/payments/pull/412" } })
  })

  test("the row menu snoozes until a preset time; the snooze timer wakes it as unread", async () => {
    const { host } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const docs = walk(host, "m").find((n) => n.type === "Row" && n.props.title === "Docs build failed")!
    const menu = docs.props.menu as Array<{ title: string; children?: Array<{ title: string }> }>
    expect(menu.map((m) => m.title)).toEqual(["Open", "Mark as Done", "Snooze", "Mark as Read"])
    expect(menu[2]!.children!.map((c) => c.title)[0]).toMatch(/^In 30 minutes \(/)
    host.dispatch("m", docs.id, "menu", { path: [2, 0] })
    await host.settle(10)
    expect(rows(host, "m")).not.toContain("Docs build failed")
    expect(texts(host, "m")).toContain("1 snoozed")
    const wake = [...host.timers.values()].find((t) => !t.repeat && t.ms > 29 * 60_000 && t.ms <= 30 * 60_000)
    expect(wake).toBeDefined()
    // Fire the wake once the time has passed (the app's clock lives in its VM).
    host.eval("Date.now = ((now) => () => now() + 31 * 60000)(Date.now)")
    fireTimers(host, (t) => !t.repeat && t.ms > 29 * 60_000)
    await host.settle(10)
    expect(rows(host, "m")).toContain("Docs build failed")
    expect(walk(host, "m").find((n) => n.type === "Row" && n.props.title === "Docs build failed")!.props.unread).toBe(true)
  })

  test("grouping by workspace loads workspace names only then", async () => {
    const { host } = inboxHost({ settings: { variant: "grouped", groupBy: "workspace" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(host.calls.some((c) => c.name === "workspace.list")).toBe(true)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["api-server", "web-dashboard", "example-org/payments", "Other"]))
    const plain = inboxHost({ settings: { variant: "grouped" } }).host
    plain.mount("m", "renderInbox", section)
    await plain.settle(20)
    expect(plain.calls.some((c) => c.name === "workspace.list")).toBe(false)
  })

  test("GitHub not granted, gateway missing, and the empty state", async () => {
    const notGranted = inboxHost({ github: "notGranted" }).host
    notGranted.mount("m", "renderInbox", section)
    await notGranted.settle(20)
    expect(rows(notGranted, "m")).toContain("Connect GitHub")
    // A refused GitHub stops its refresh timer.
    fireTimers(notGranted, (t) => t.repeat)
    expect([...notGranted.timers.values()].some((t) => t.repeat)).toBe(false)

    const unavailable = inboxHost({ github: "unavailable" }).host
    unavailable.mount("m", "renderInbox", section)
    await unavailable.settle(20)
    expect(rows(unavailable, "m")).toContain("GitHub through cmux is not available yet")

    const empty = inboxHost({ empty: true }).host
    empty.mount("m", "renderInbox", section)
    await empty.settle(20)
    expect(walk(empty, "m").find((n) => n.type === "EmptyState")!.props.title).toBe("Nothing needs you")
  })
})

describe("focus variant", () => {
  test("a click selects; the detail shows the agent's screen and its actions", async () => {
    const { host } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["Needs input", "Allow running the test suite", "Open", "Done", "Snooze"]))
    expect(texts(host, "m").some((s) => s.includes("npm test -- --runInBand"))).toBe(true)
    host.dispatch("m", nodeWith(host, "m", "Row", "Retry webhook delivery with backoff")!, "tap")
    await host.settle(20)
    expect(host.calls.some((c) => c.name === "action.run")).toBe(false)
    expect(texts(host, "m")).toContain("2 failed: unit tests, integration")
    host.dispatch("m", nodeWith(host, "m", "Button", "Done")!, "tap")
    await host.settle(20)
    expect(rows(host, "m")).not.toContain("Retry webhook delivery with backoff")
    // The selection moved to the next item.
    expect(walk(host, "m").find((n) => n.type === "Row" && n.props.selected === true)!.props.title).toBe("Add idempotency keys to refunds")
  })

  test("quick reply types into the agent's terminal, or explains the missing scope", async () => {
    const { host } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const field = walk(host, "m").find((n) => n.type === "TextField")!
    host.dispatch("m", field.id, "submit", { text: "1" })
    await host.settle(10)
    expect(host.calls.find((c) => c.name === "terminal.input.write")!.params).toEqual({ terminal: "terminal_1", text: "1\r" })

    const blocked = inboxHost({ settings: { variant: "focus" }, replyScope: false }).host
    blocked.mount("m", "renderInbox", section)
    await blocked.settle(20)
    blocked.dispatch("m", walk(blocked, "m").find((n) => n.type === "TextField")!.id, "submit", { text: "1" })
    await blocked.settle(10)
    expect(texts(blocked, "m").some((s) => s.startsWith("Quick reply needs permission"))).toBe(true)
    expect(walk(blocked, "m").some((n) => n.type === "TextField")).toBe(false)
  })
})

describe("card variant", () => {
  test("one item at a time; Skip moves on and Done finishes", async () => {
    const { host } = inboxHost({ settings: { variant: "card" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["1 of 8", "Claude", "Skip"]))
    host.dispatch("m", nodeWith(host, "m", "Button", "Skip")!, "tap")
    await host.settle(10)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["2 of 8", "Docs build failed"]))
    host.dispatch("m", nodeWith(host, "m", "Button", "Done")!, "tap")
    await host.settle(10)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["2 of 7", "Retry webhook delivery with backoff"]))
  })

  test("the variant command cycles and stores the override when settings are read-only", async () => {
    const { host, storage } = inboxHost({ settings: { variant: "card" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const r = await command(host, "cycleVariant")
    expect(r).toEqual({ ok: true, body: { value: { variant: "grouped" } } })
    await host.settle(10)
    expect(storage.get("variantOverride")).toEqual({ variant: "grouped", base: "card" })
    expect(texts(host, "m")).toContain("Agents")
  })
})

describe("status item and commands", () => {
  test("the badge counts unread items; a click opens the most urgent one", async () => {
    const { host } = inboxHost()
    host.mount("s", "renderStatus", { contribution: "cmux/inbox#badge", surface: "statusItem" })
    await host.settle(20)
    const nodes = walk(host, "s")
    expect(nodes.find((n) => n.type === "Badge")!.props).toMatchObject({ text: "4", tone: "warning" })
    host.dispatch("s", nodes[0]!.id, "tap")
    await host.settle(10)
    expect(host.calls.find((c) => c.name === "tab.focus")!.params).toEqual({ tab: "tab_1" })
    expect((nodes[0]!.props.menu as Array<{ title: string }>)[0]!.title).toBe("Needs input: Claude")
  })

  test("list, markDone and snooze work with nothing mounted (MCP tools)", async () => {
    const { host } = inboxHost()
    const listed = await command(host, "list", { source: "github" })
    expect(listed.ok).toBe(true)
    const value = listed.body.value as { items: Array<{ id: string; kind: string }> }
    expect(value.items.map((i) => i.kind)).toEqual(["checksFailing", "reviewRequested", "mention"])
    expect(await command(host, "markDone", { id: "github:example-org/payments#412" })).toEqual({ ok: true, body: { value: { id: "github:example-org/payments#412", done: true } } })
    const snoozed = await command(host, "snooze", { id: "agent:agent_2", minutes: 90 })
    expect(snoozed.ok).toBe(true)
    const after = (await command(host, "list", {})).body.value as { items: Array<{ id: string }> }
    expect(after.items.map((i) => i.id)).not.toContain("github:example-org/payments#412")
    expect(after.items.map((i) => i.id)).not.toContain("agent:agent_2")
    const missing = await command(host, "markDone", { id: "nope" })
    expect(missing.ok).toBe(false)
    expect(missing.body.code).toBe("item.not_found")
  })

  test("next item selects and opens in order; mark all read acks every unread notification", async () => {
    const { host } = inboxHost()
    expect((await command(host, "nextItem")).body.value).toEqual({ id: "agent:agent_1" })
    expect((await command(host, "nextItem", { open: false })).body.value).toEqual({ id: "notification:notification_2" })
    expect(host.calls.filter((c) => c.name === "tab.focus")).toHaveLength(1)
    const r = await command(host, "markAllRead")
    expect(r.body.value).toEqual({ marked: 3 })
    const acked = host.calls.filter((c) => c.name === "notification.ack").flatMap((c) => c.params.notifications)
    expect(acked.sort()).toEqual(["notification_1", "notification_2", "notification_3"])
  })

  test("open inbox reports the missing pane op", async () => {
    const { host } = inboxHost()
    const r = await command(host, "openInbox")
    expect(r.ok).toBe(false)
    expect(host.calls.find((c) => c.name === "app.pane.open")!.params).toEqual({ contribution: "cmux/inbox#pane" })
  })
})
