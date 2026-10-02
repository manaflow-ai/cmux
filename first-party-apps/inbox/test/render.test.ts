import { describe, expect, test } from "bun:test"
import { fid } from "./fixtures.ts"
import { command, inboxHost, menu, nodeWith, rows, tap, texts, walk } from "./host.ts"

const section = { contribution: "cmux/inbox#inbox", surface: "sidebarSection" }
const lists = (host: ReturnType<typeof inboxHost>["host"]) => host.calls.filter((c) => c.name === "feed.list").length
const rowNode = (host: ReturnType<typeof inboxHost>["host"], title: string) => walk(host, "m").find((n) => n.type === "Row" && n.props.title === title)!
type MenuEntry = { title: string; children?: MenuEntry[] }

const ACTIVE = [
  "Name for the backup volume?",
  "Sign in to the staging dashboard",
  "Run npm install --save chart-kit?",
  "Which retry strategy should the webhook sender use?",
  "Add idempotency keys to refunds",
  "Delete 4 stale preview databases?",
  "Preview deployed",
  "Finished: dark mode toggle",
  "Checks failing: Retry webhook delivery with backoff",
  "Disk space low"
]

describe("grouped variant", () => {
  test("renders the owner's groups; a click opens through feed.openItem with the tap's gesture", async () => {
    const { host, actions } = inboxHost({ settings: { variant: "grouped" } })
    expect(host.mount("m", "renderInbox", section)).toBe("")
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "feed.list")!.params).toEqual({ state: "open", order: "urgent", group_by: "poster", limit: 100 })
    expect(rows(host, "m")).toEqual([ACTIVE[0], ACTIVE[1], ACTIVE[3], ACTIVE[2], ACTIVE[7], ACTIVE[4], ACTIVE[8], ACTIVE[5], ACTIVE[6], ACTIVE[9]])
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["nightly-backup", "Claude", "Codex", "GitHub", "preview-deploy", "Disk Monitor"]))
    expect(walk(host, "m").find((n) => n.type === "Badge")!.props).toMatchObject({ text: "6", tone: "warning" })
    const before = lists(host)
    tap(host, "m", rowNode(host, "Finished: dark mode toggle").id)
    expect(actions).toEqual([{ id: "feed.openItem", args: { item: fid("darkmode") }, gesture: expect.any(String) }])
    await host.settle(20)
    // The owner's read event patches the row; nothing is listed again.
    expect(rowNode(host, "Finished: dark mode toggle").props.unread).toBe(false)
    expect(lists(host)).toBe(before)
    expect(host.calls.some((c) => c.name === "action.run" && /tab\.(show|focus)|browser\./.test(c.params.id))).toBe(false)
  })

  test("an open request offers answers and Decline, never Done or Snooze; an answer leaves the list from its event", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const row = rowNode(host, "Run npm install --save chart-kit?")
    const entries = row.props.menu as MenuEntry[]
    expect(entries.map((m) => m.title)).toEqual(["Open", "Answer", "Decline", "Mark as Read"])
    expect(entries[1]!.children!.map((c) => c.title)).toEqual(["Allow", "Allow for Session", "Deny"])
    const before = lists(host)
    menu(host, "m", row.id, [1, 1])
    const call = host.calls.find((c) => c.name === "feed.answer")!
    expect(call.params).toEqual({ item: fid("npminstall"), answer: { decision: "allow", scope: "session" } })
    expect(call.options.gesture).toBe(`g_${row.id}`)
    await host.settle(20)
    expect(owner.answers).toEqual([{ item: fid("npminstall"), answer: { decision: "allow", scope: "session" } }])
    expect(rows(host, "m")).not.toContain("Run npm install --save chart-kit?")
    expect(lists(host)).toBe(before)
    expect(walk(host, "m").find((n) => n.type === "Badge")!.props).toMatchObject({ text: "5" })
  })

  test("the user declines a request; the waiting agent gets reason declined", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const row = rowNode(host, "Delete 4 stale preview databases?")
    const titles = (row.props.menu as MenuEntry[]).map((m) => m.title)
    menu(host, "m", row.id, [titles.indexOf("Decline")])
    expect(host.calls.find((c) => c.name === "feed.cancel")!.params).toEqual({ item: fid("dropdbs"), reason: "declined" })
    await host.settle(20)
    expect(owner.get(fid("dropdbs"))!.cancel!.reason).toBe("declined")
    expect(rows(host, "m")).not.toContain("Delete 4 stale preview databases?")
  })

  test("an answer without a user gesture is never sent", async () => {
    const { host } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const row = rowNode(host, "Run npm install --save chart-kit?")
    host.dispatch("m", row.id, "menu", { path: [1, 0] }) // no gesture token
    await host.settle(20)
    expect(host.calls.some((c) => c.name === "feed.answer")).toBe(false)
    expect(texts(host, "m")).toContain("Answer from the inbox or the feed: only you answer requests.")
  })

  test("a notice can be done or snoozed; the owner fires the wake-up and the app arms no timer", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const row = rowNode(host, "Disk space low")
    expect((row.props.menu as MenuEntry[]).map((m) => m.title)).toEqual(["Open", "Mark as Done", "Snooze"])
    menu(host, "m", row.id, [2, 0])
    await host.settle(20)
    const call = host.calls.find((c) => c.name === "feed.snooze")!
    expect(call.params.items).toEqual([fid("diskspace")])
    expect(call.params.until - Date.now()).toBeGreaterThan(29 * 60_000)
    expect(owner.get(fid("diskspace"))!.snoozed_until).toBe(call.params.until)
    expect(rows(host, "m")).not.toContain("Disk space low")
    expect([...host.timers.values()].filter((t) => t.ms > 60_000)).toHaveLength(0)
  })

  test("events that bring items the page cannot know list again, once per burst", async () => {
    const { host, owner, emit, now } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const before = lists(host)
    const base = owner.get(fid("darkmode"))!
    emit(owner.post({ ...structuredClone(base), id: fid("newnotice"), title: "Tests passed on main", read_at: null, created_at: now, updated_at: now }))
    emit(owner.unarchive({ items: [fid("backupdone")] }))
    await host.settle(20)
    expect(lists(host)).toBe(before + 1)
    expect(rows(host, "m")).toEqual(expect.arrayContaining(["Tests passed on main", "Nightly backup finished"]))
  })

  test("filters and grouping go to the owner, never applied locally", async () => {
    const { host, storage } = inboxHost({ settings: { variant: "grouped", groupBy: "workspace" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["api-server", "web-dashboard", "Other"]))
    const filterMenu = walk(host, "m").find((n) => n.type === "Menu" && n.props.title === "All")!
    const titles = (filterMenu.props.menu as Array<{ title?: string }>).map((m) => m.title)
    menu(host, "m", filterMenu.id, [titles.indexOf("Show Only What Needs an Answer")])
    await host.settle(20)
    expect(host.calls.filter((c) => c.name === "feed.list").at(-1)!.params).toEqual({ state: "open", order: "urgent", needs_response: true, group_by: "workspace", limit: 100 })
    expect(rows(host, "m")).toHaveLength(6)
    expect((storage.get("view") as { filters: { needsResponseOnly: boolean } }).filters.needsResponseOnly).toBe(true)
  })

  test("Show Done lists archived items; Move Back to Inbox unarchives", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "grouped" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const nodes = walk(host, "m")
    const label = nodes.findIndex((n) => n.type === "Text" && n.props.text === "Show Done")
    tap(host, "m", nodes.slice(0, label).reverse().find((n) => n.props.onTap)!.id)
    await host.settle(20)
    expect(host.calls.filter((c) => c.name === "feed.list").at(-1)!.params).toEqual({ state: "all", archived: true, order: "recent", group_by: "poster", limit: 100 })
    expect(rows(host, "m")).toEqual(["Nightly backup finished"])
    const row = rowNode(host, "Nightly backup finished")
    expect((row.props.menu as MenuEntry[]).map((m) => m.title)).toEqual(["Open", "Move Back to Inbox"])
    menu(host, "m", row.id, [1])
    await host.settle(20)
    expect(owner.get(fid("backupdone"))!.archived_at).toBeNull()
    expect(rows(host, "m")).toEqual([])
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
  test("a click selects and reads; a one-tap choice answers in the owner's shape", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "feed.list")!.params).toEqual({ state: "open", order: "urgent", limit: 100 })
    tap(host, "m", rowNode(host, "Which retry strategy should the webhook sender use?").id)
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "feed.read")!.params).toEqual({ items: [fid("retrychoice")] })
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["Exponential backoff", "Fixed 30 s delay", "Move failures to a retry queue", "Open", "Decline"]))
    expect(texts(host, "m")).not.toContain("Done")
    tap(host, "m", nodeWith(host, "m", "Button", "Fixed 30 s delay")!)
    await host.settle(20)
    expect(owner.answers).toEqual([{ item: fid("retrychoice"), answer: { answers: { strategy: { selected: ["fixed"] } } } }])
    expect(walk(host, "m").find((n) => n.type === "Row" && n.props.selected === true)!.props.title).toBe("Add idempotency keys to refunds")
  })

  test("an input request sends its form once the required field is filled", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    const field = walk(host, "m").find((n) => n.type === "TextField" && n.props.placeholder === "Volume name *")!
    expect(walk(host, "m").find((n) => n.type === "Button" && n.props.title === "Send")!.props.disabled).toBe(true)
    host.dispatch("m", field.id, "edit", { text: " backups-02 " })
    await host.settle(5)
    tap(host, "m", nodeWith(host, "m", "Button", "Send")!)
    await host.settle(20)
    expect(owner.answers).toEqual([{ item: fid("volumename"), answer: { volume: "backups-02" } }])
  })

  test("a sign-in request goes through feed.openItem (the handover), never a bare browser action, and is not answered by the app", async () => {
    const { host, owner, actions } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    tap(host, "m", rowNode(host, "Sign in to the staging dashboard").id)
    await host.settle(20)
    expect(texts(host, "m")).not.toContain("Open")
    tap(host, "m", nodeWith(host, "m", "Button", "Continue in Browser")!)
    await host.settle(20)
    expect(actions.map((a) => a.id)).toEqual(["feed.openItem"])
    expect(actions[0]!.args).toEqual({ item: fid("signin") })
    expect(owner.answers).toEqual([])
    expect(owner.get(fid("signin"))!.state).toBe("open")
  })

  test("a notice shows Done and Snooze, and its poster's open-only buttons", async () => {
    const { host, owner } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    tap(host, "m", rowNode(host, "Checks failing: Retry webhook delivery with backoff").id)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["Open", "View Checks", "Done", "Snooze"]))
    tap(host, "m", nodeWith(host, "m", "Button", "Done")!)
    await host.settle(20)
    expect(owner.get(fid("checksfail"))!.archived_at).not.toBeNull()
    expect(rows(host, "m")).not.toContain("Checks failing: Retry webhook delivery with backoff")
  })
})

describe("card variant", () => {
  test("one item at a time; Skip moves on; an approval offers Allow and Deny", async () => {
    const { host } = inboxHost({ settings: { variant: "card" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["1 of 10", "Name for the backup volume?", "Skip", "Decline"]))
    tap(host, "m", nodeWith(host, "m", "Button", "Skip")!)
    await host.settle(10)
    tap(host, "m", nodeWith(host, "m", "Button", "Skip")!)
    await host.settle(10)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["3 of 10", "Run npm install --save chart-kit?", "Allow", "Allow for Session", "Deny", "npm install --save chart-kit"]))
  })

  test("Next Inbox Variant writes the setting through the config layer", async () => {
    const { host } = inboxHost({ settings: { variant: "card" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    expect(await command(host, "cycleVariant")).toEqual({ ok: true, body: { value: { variant: "grouped" } } })
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "app.settings.set")!.params).toEqual({ values: { variant: "grouped" } })
    expect(texts(host, "m")).toContain("Claude")
  })
})

describe("status item and commands", () => {
  test("the badge and menu follow the owner's events (an answer on another device)", async () => {
    const { host, owner, emit } = inboxHost()
    host.mount("s", "renderStatus", { contribution: "cmux/inbox#badge", surface: "statusItem" })
    await host.settle(20)
    expect(walk(host, "s").find((n) => n.type === "Badge")!.props).toMatchObject({ text: "6", tone: "warning" })
    expect(host.calls.find((c) => c.name === "feed.list")!.params).toEqual({ state: "open", order: "urgent", limit: 8 })
    expect((walk(host, "s")[0]!.props.menu as MenuEntry[])[0]!.title).toBe("Input: Name for the backup volume?")
    emit(owner.answer({ item: fid("volumename"), answer: { volume: "v2" } }, "phone"))
    await host.settle(20)
    expect(walk(host, "s").find((n) => n.type === "Badge")!.props).toMatchObject({ text: "5", tone: "warning" })
    expect((walk(host, "s")[0]!.props.menu as MenuEntry[])[0]!.title).toBe("Sign-in: Sign in to the staging dashboard")
  })

  test("commands never answer; open requests cannot be marked done or snoozed", async () => {
    const { host, owner } = inboxHost()
    expect(await command(host, "markDone", { id: fid("npminstall") })).toMatchObject({ ok: false, body: { code: "feed.open_request" } })
    expect(await command(host, "snooze", { id: fid("npminstall") })).toMatchObject({ ok: false, body: { code: "feed.open_request" } })
    expect(await command(host, "markDone", { id: fid("darkmode") })).toEqual({ ok: true, body: { value: { id: fid("darkmode"), done: true } } })
    expect(owner.get(fid("darkmode"))!.archived_at).not.toBeNull()
    expect((await command(host, "snooze", { id: fid("diskspace"), minutes: 90 })).ok).toBe(true)
    expect(await command(host, "markDone", { id: "fi_nope" })).toMatchObject({ ok: false, body: { code: "item.not_found" } })
    expect((await command(host, "answer", { id: fid("npminstall") })).body.code).toBe("export.missing")
  })

  test("next item opens in the owner's order; Mark All as Read is one owner call", async () => {
    const { host, owner, actions } = inboxHost()
    expect((await command(host, "nextItem")).body.value).toEqual({ id: fid("volumename") })
    expect((await command(host, "nextItem", { open: false })).body.value).toEqual({ id: fid("signin") })
    expect(actions.map((a) => a.args)).toEqual([{ item: fid("volumename") }])
    expect(await command(host, "markAllRead")).toEqual({ ok: true, body: { value: { read: true } } })
    expect(host.calls.filter((c) => c.name === "feed.read").at(-1)!.params).toEqual({ all: true })
    expect(owner.counts().unread).toBe(0)
  })

  test("the app stores only view preferences, never item state", async () => {
    const { host, storage } = inboxHost({ settings: { variant: "focus" } })
    host.mount("m", "renderInbox", section)
    await host.settle(20)
    await command(host, "markDone", { id: fid("darkmode") })
    await command(host, "snooze", { id: fid("diskspace") })
    for (const key of storage.keys()) expect(key).toBe("view")
  })
})
