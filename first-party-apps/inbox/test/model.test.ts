import { describe, expect, test } from "bun:test"
import { parseSearch } from "../src/github.ts"
import { emptyLedger, markDone, markSeen, snooze } from "../src/ledger.ts"
import { buildItems, countItems, filterItems, groupItems, DEFAULT_FILTERS, itemJSON, locateTerminals, neighbor, type Sources } from "../src/model.ts"
import { githubData, sessionData } from "./fixtures.ts"

const NOW = Date.UTC(2026, 9, 2, 12, 0)
const CLIENT = "app:cmux/inbox"

function sources(over: Partial<Sources> = {}): Sources {
  const s = sessionData(NOW)
  const g = githubData(NOW)
  return {
    agents: s.agents as never,
    notifications: s.notifications as never,
    terminals: new Map(s.terminals.map((x) => [x.id, x as never])),
    github: [...parseSearch("reviewRequested", g.review), ...parseSearch("checksFailing", g.failing), ...parseSearch("mention", g.mention)],
    locations: locateTerminals(s as never),
    ...over
  }
}

const options = { clientId: CLIENT, includeIdle: false, includeDone: true, maxAgeDays: 7, now: NOW }

describe("buildItems", () => {
  test("folds an agent's notifications into its item and orders by urgency", () => {
    const items = buildItems(sources(), emptyLedger(), options, "Agent")
    expect(items.map((i) => i.id)).toEqual([
      "agent:agent_1",
      "notification:notification_2",
      "github:example-org/api-server#88",
      "github:example-org/payments#412",
      "agent:agent_2",
      "notification:notification_3",
      "github:example-org/design-system#1203",
      "notification:notification_4"
    ])
    const claude = items[0]!
    expect(claude.title).toBe("Claude")
    expect(claude.kind).toBe("agentBlocked")
    expect(claude.notifications).toEqual(["notification_1"])
    expect(claude.detail).toBe("Allow running the test suite")
    expect(claude.workspace).toEqual({ id: "workspace_1", name: "api-server" })
    // Working agents never appear; the folded notification is not listed twice.
    expect(items.some((i) => i.id === "agent:agent_3" || i.id === "notification:notification_1")).toBe(false)
  })

  test("a notification this app acknowledged is read", () => {
    const s = sessionData(NOW)
    const acked = s.notifications.map((n) => (n.id === "notification_2" ? { ...n, read_by: [CLIENT] } : n))
    const items = buildItems(sources({ notifications: acked as never }), emptyLedger(), options, "Agent")
    expect(items.find((i) => i.id === "notification:notification_2")!.unread).toBe(false)
    expect(items.find((i) => i.id === "notification:notification_3")!.unread).toBe(true)
  })

  test("done hides an item until it changes again", () => {
    const first = buildItems(sources(), emptyLedger(), options, "Agent")
    const ledger = markDone(emptyLedger(), [first[0]!])
    expect(buildItems(sources(), ledger, options, "Agent").some((i) => i.id === "agent:agent_1")).toBe(false)
    const later = sessionData(NOW).agents.map((a) => (a.id === "agent_1" ? { ...a, updated_at_ms: String(NOW + 60_000) } : a))
    const back = buildItems(sources({ agents: later as never }), ledger, { ...options, now: NOW + 60_000 }, "Agent")
    expect(back.find((i) => i.id === "agent:agent_1")!.unread).toBe(true)
  })

  test("idle agents only when asked; old notifications age out but agents never do", () => {
    const s = sessionData(NOW)
    const idle = s.agents.map((a) => (a.id === "agent_2" ? { ...a, state: "idle", updated_at_ms: String(NOW - 30 * 86_400_000) } : a))
    expect(buildItems(sources({ agents: idle as never }), emptyLedger(), options, "Agent").some((i) => i.id === "agent:agent_2")).toBe(false)
    expect(buildItems(sources({ agents: idle as never }), emptyLedger(), { ...options, includeIdle: true }, "Agent").some((i) => i.id === "agent:agent_2")).toBe(true)
    const old = s.notifications.map((n) => ({ ...n, created_at_ms: String(NOW - 8 * 86_400_000) }))
    const items = buildItems(sources({ notifications: old as never }), emptyLedger(), options, "Agent")
    expect(items.filter((i) => i.source === "notification")).toEqual([])
    expect(buildItems(sources({ notifications: old as never }), emptyLedger(), { ...options, maxAgeDays: 0 }, "Agent").filter((i) => i.source === "notification")).toHaveLength(3)
  })
})

describe("filters, groups, counts", () => {
  const ledger = snooze(markSeen(emptyLedger(), [{ id: "notification:notification_3", at: NOW }]), ["github:example-org/payments#412"], NOW + 3_600_000)
  const items = buildItems(sources(), ledger, options, "Agent")

  test("snoozed items leave the list and show only in the snoozed view", () => {
    expect(filterItems(items, DEFAULT_FILTERS).some((i) => i.id === "github:example-org/payments#412")).toBe(false)
    expect(filterItems(items, { ...DEFAULT_FILTERS, showSnoozed: true }).map((i) => i.id)).toEqual(["github:example-org/payments#412"])
  })

  test("source, unread and mine filters", () => {
    expect(filterItems(items, { ...DEFAULT_FILTERS, source: "github" }).map((i) => i.kind)).toEqual(["checksFailing", "mention"])
    expect(filterItems(items, { ...DEFAULT_FILTERS, unreadOnly: true }).every((i) => i.unread)).toBe(true)
    expect(filterItems(items, { ...DEFAULT_FILTERS, mineOnly: true }).some((i) => i.kind === "mention")).toBe(false)
  })

  test("group by source keeps a fixed order; by workspace uses names, repositories, then other", () => {
    const open = filterItems(items, DEFAULT_FILTERS)
    expect(groupItems(open, "source", "Other").map((g) => g.key)).toEqual(["agent", "notification", "github"])
    const byWorkspace = groupItems(open, "workspace", "Other")
    expect(byWorkspace.map((g) => g.label)).toEqual(["api-server", "example-org/api-server", "web-dashboard", "example-org/design-system", "Other"])
    expect(byWorkspace.find((g) => g.label === "api-server")!.items.map((i) => i.id)).toEqual(["agent:agent_1", "notification:notification_2"])
  })

  test("counts ignore snoozed items; blocked agents are counted", () => {
    // Unread: both agents, the docs build failure, and two GitHub items (the disk notice was seen, the deploy notice was read).
    expect(countItems(items)).toEqual({ unread: 5, blocked: 1, open: 7, snoozed: 1 })
  })
})

test("neighbor wraps and starts at the ends", () => {
  const order = [{ id: "a" }, { id: "b" }, { id: "c" }]
  expect(neighbor(order, "c", 1)).toBe("a")
  expect(neighbor(order, "a", -1)).toBe("c")
  expect(neighbor(order, null, 1)).toBe("a")
  expect(neighbor(order, "gone", -1)).toBe("c")
  expect(neighbor([], "a", 1)).toBeNull()
})

test("itemJSON is stable for agents", () => {
  const item = buildItems(sources(), emptyLedger(), options, "Agent")[2]!
  expect(itemJSON(item)).toEqual({
    id: "github:example-org/api-server#88",
    source: "github",
    kind: "checksFailing",
    title: "Retry webhook delivery with backoff",
    detail: "api-server #88",
    unread: true,
    updated_at: new Date(NOW - 70 * 60_000).toISOString(),
    snoozed_until: null,
    workspace: null,
    terminal_id: null,
    url: "https://github.com/example-org/api-server/pull/88",
    repo: "example-org/api-server",
    number: 88,
    level: null
  })
})
