import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import { FakeHost } from "./fake-host.ts"

const profile = new URL("../../../../../examples/looks/session-recents/", import.meta.url)
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
