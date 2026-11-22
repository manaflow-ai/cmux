import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import { FakeHost } from "./fake-host.ts"

const profile = new URL("../../../../../examples/looks/claude-code/session-recents/", import.meta.url)
const manifest = JSON.parse(readFileSync(new URL("customize/cmux-app.json", profile)))
const source = readFileSync(new URL("customize/" + manifest.runtime.main, profile), "utf8")
const now = Date.UTC(2026, 10, 21)
const week = 7 * 86400000
const ok = (value) => ({ ok: true, body: { value } })
const pinKey = (machine, id) => JSON.stringify([machine, id])

async function mount(chats, storage = {}) {
  const host = new FakeHost(source)
  host.eval("Date.now = () => " + now)
  host.handlers["chat.list"] = ({ include_archived }) => ok(chats.filter((c) => include_archived || !c.archived))
  host.handlers["app.storage.get"] = ({ key }) => ok(storage[key] ?? null)
  host.handlers["app.storage.set"] = ({ key, value }) => ok(storage[key] = value)
  host.handlers["action.run"] = () => ok(null)
  assert.equal(host.mount("recents", manifest.implements["cmux.section/1"].export), "")
  await host.settle()
  return host
}

// Traverse the live tree in display order after reconciliation.
function drawn(host) {
  const { nodes, root } = host.tree("recents")
  function walk(id) {
    const n = nodes.get(id)
    return [{ ...n, id }, ...n.children.flatMap(walk)]
  }
  return walk(root)
}

function node(host, type, title) {
  const found = drawn(host).find((n) => n.type === type && (title === undefined || n.props.title === title))
  assert.ok(found, type + " " + (title || ""))
  return found
}

async function choose(host, type, title, command) {
  const control = node(host, type, title)
  const index = control.props.menu.findIndex((item) => item.title === command && !item.disabled)
  assert.notEqual(index, -1, command)
  host.dispatch("recents", control.id, "menu", { path: [index], gesture: "from-click" })
  await host.settle()
}

const titles = (host) => drawn(host).filter((n) => n.type === "Row").map((n) => n.props.title)
const headings = (host) => drawn(host).filter((n) => n.type === "Text").map((n) => n.props.text)

test("nested rows open on their machine and can be grouped by agent or project", async () => {
  const host = await mount([
    { id: "a", title: "Local", harness: "codex", cwd: "/repo" },
    { id: "b", parent: "a", title: "Child", harness: "codex", cwd: "/repo" },
    { id: "a", machine: "peer", title: "Remote", harness: "claude", cwd: "/other" },
  ])
  assert.equal(node(host, "Row", "Child").props.padding.leading, 12)
  host.dispatch("recents", node(host, "Row", "Remote").id, "tap", { gesture: "open" })
  await host.settle()
  assert.deepEqual(host.calls.at(-1), { name: "action.run", params: { id: "agent.openSessionTab", args: { session: "a", host: "peer" } }, options: { gesture: "open" } })
  await choose(host, "Menu", "Sessions", "Agents")
  assert.deepEqual(headings(host), ["codex", "claude"])
  await choose(host, "Menu", "Agents", "Projects")
  assert.deepEqual(headings(host), ["/repo", "/other"])
  assert.deepEqual(titles(host), ["Local", "Child", "Remote"])
})

test("moving pins with the same id persists the order through a remount", async () => {
  const chats = [
    { id: "p", title: "Local pin", pinned: true, updated_ms: now },
    { id: "p", machine: "peer", title: "Peer pin", pinned: true },
  ]
  const storage = {}
  const host = await mount(chats, storage)
  assert.deepEqual(titles(host), ["Local pin", "Peer pin"])
  host.dispatch("recents", node(host, "Reorderable").id, "move", { id: pinKey("peer", "p"), index: 0 })
  await host.settle()
  assert.deepEqual(storage["session-recents.pin-order"], [pinKey("peer", "p"), pinKey("", "p")])
  assert.deepEqual(titles(await mount(chats, storage)), ["Peer pin", "Local pin"])
})

function archiveHandler(host, chats, refuses = () => false) {
  host.handlers["chat.archive"] = ({ targets, archived }, options) => {
    assert.equal(options.gesture, "from-click")
    const result = targets.map(({ chat, peer }) => {
      const row = chats.find((r) => r.id === chat && (r.machine ?? null) === peer)
      assert.ok(row, "qualified archive target")
      const error = refuses(row) ? "unavailable" : null
      if (!error) row.archived = archived
      return { chat, peer, error }
    })
    host.emit("chat.changed")
    return ok(result)
  }
}
const calls = (host, name) => host.calls.filter((c) => c.name === name)

test("age archive uses last activity, skips pins and unknown ages, and preserves younger children", async () => {
  const chats = [
    { id: "old", created_ms: String(now - 2 * week) },
    { id: "new", parent: "old", updated_ms: String(now) },
    { id: "active", created_ms: now - 2 * week, since_ms: now },
    { id: "boundary", updated_ms: now - week },
    { id: "unknown" }, { id: "pin", pinned: true, created_ms: now - 3 * week },
    { id: "archived", archived: true, created_ms: now - 2 * week },
  ]
  const host = await mount(chats)
  archiveHandler(host, chats)
  await choose(host, "Menu", "Archive", "Archive older than a week")
  assert.deepEqual(calls(host, "chat.archive").map((c) => c.params), [{ targets: [{ chat: "old", peer: null }], archived: true }])
  assert.equal(node(host, "Row", "new").props.padding.leading, 0)
  await choose(host, "Menu", "Archive", "Archive all recent sessions")
  assert.deepEqual(titles(host), ["pin"])
  await choose(host, "Menu", "Archive", "Show archived")
  assert.deepEqual(titles(host).sort(), ["active", "archived", "boundary", "new", "old", "unknown"])
})

test("explicit nested archive and restore stay on the selected peer through partial failure and retry", async () => {
  const chats = [
    { id: "root", title: "Local" },
    { id: "root", title: "Remote", machine: "peer" },
    { id: "child", title: "Nested", machine: "peer", parent: "root" },
    { id: "child", title: "Local child", parent: "root" },
  ]
  const host = await mount(chats)
  archiveHandler(host, chats, (r) => r.title === "Nested")
  await choose(host, "Row", "Remote", "Archive with nested sessions")
  assert.deepEqual(calls(host, "chat.archive")[0].params.targets, [{ chat: "root", peer: "peer" }, { chat: "child", peer: "peer" }])
  assert.ok(headings(host).some((s) => s.includes("1 archived, 1 failed") && s.includes("peer/child")))
  archiveHandler(host, chats)
  await choose(host, "Row", "Nested", "Archive")
  await choose(host, "Menu", "Archive", "Show archived")
  assert.deepEqual(titles(host), ["Remote", "Nested"])
  assert.deepEqual(node(host, "Row", "Remote").props.menu.map((item) => item.title), ["Open", "Restore", "Restore with nested sessions"])
  await choose(host, "Row", "Remote", "Restore with nested sessions")
  assert.deepEqual(titles(host), [])
  assert.ok(headings(host).includes("No archived sessions"))
  assert.equal(chats.filter((r) => r.archived).length, 0)
})

test("pinning a peer uses its exact selector; the new pin appears on chat.changed", async () => {
  const chats = [{ id: "one", title: "Local" }, { id: "one", machine: "other", title: "Remote" }]
  const host = await mount(chats)
  host.handlers["chat.pin"] = (params, options) => {
    assert.deepEqual(params, { chat: "one", peer: "other", pinned: true })
    assert.equal(options.gesture, "from-click")
    chats[1].pinned = true
    host.emit("chat.changed")
    return ok(null)
  }
  await choose(host, "Row", "Remote", "Pin")
  assert.deepEqual(titles(host), ["Remote", "Local"])
  assert.ok(headings(host).includes("Pinned"))
})

test("second pin page reorders using the full list", async () => {
  const chats = Array.from({ length: 21 }, (_, i) => ({ id: String(i), pinned: true, updated_ms: now - i }))
  const storage = {}
  const host = await mount(chats, storage)
  host.dispatch("recents", node(host, "Button", "Next").id, "tap")
  await host.settle()
  assert.deepEqual(titles(host), ["17", "18", "19", "20"])
  host.dispatch("recents", node(host, "Reorderable").id, "move", { id: pinKey("", "20"), index: 0 })
  await host.settle()
  assert.equal(storage["session-recents.pin-order"].length, chats.length)
  assert.deepEqual(titles(host), ["20", "17", "18", "19"])
})
