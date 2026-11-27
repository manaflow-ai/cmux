import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { FakeHost } from "../../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const read = path => readFileSync(new URL(path, import.meta.url), "utf8")
const manifest = JSON.parse(read("customize/cmux-app.json"))
const host = new FakeHost(read("customize/main.js"))
const ok = value => ({ ok: true, body: { value } })
let chats = [
  { id: "same-id", title: "Local draft", state: "idle", updated_ms: 2 },
  { id: "same-id", title: "Remote build", state: "working", machine: "lab", updated_ms: 3 }
]
host.handlers["agent_chat.list"] = () => ok({ chats })
host.handlers["action.run"] = () => ok({})
function mount(id, iface) {
  assert.equal(host.mount(id, manifest.implements[iface].export), "")
}
// Only nodes still attached under the root count; a detached subtree can stay in the store.
function attached(id, pred) {
  const { root, nodes } = host.tree(id)
  const stack = [root]
  while (stack.length) {
    const key = stack.pop()
    const n = nodes.get(key)
    if (!n) continue
    if (pred(n)) return key
    stack.push(...n.children)
  }
  return undefined
}
function nodeIn(id, label) {
  return attached(id, n => [n.props.text, n.props.title, n.props.placeholder].includes(label))
}
async function dispatch(id, label, event = "tap", payload = {}) {
  const node = nodeIn(id, label)
  assert.ok(node, `${id} missing ${label}`)
  host.dispatch(id, node, event, { gesture: "tap", ...payload })
  await host.settle()
}
async function action(id, label, expected, args = {}, event = "tap") {
  const count = host.calls.length
  await dispatch(id, label, event)
  const calls = host.calls.slice(count).filter(call => call.name === "action.run")
  assert.deepEqual(calls.map(call => call.params), [{ id: expected, args }])
}
const listReads = () => host.calls.filter(c => c.name === "agent_chat.list").length
mount("hosts", "cmux.section/1")
mount("tab", "cmux.newtab/1")
await host.settle()
assert.equal(listReads(), 1)
assert.equal(host.subscriptions.size, 1)
assert.ok(nodeIn("tab", "Local draft") && nodeIn("tab", "Remote build"))
await action("tab", "New Tab in Session", "newSurface")
await action("tab", "New Local Session", "workspace.newOnMachine", { machine: "local" })
await action("tab", "New Session on Host…", "palette.open", { query: "New Workspace on Machine" })
await action("tab", "Add Remote Host…", "remote.connect")
await action("tab", "New local chat", "palette.newAgentChat", { host: "local" })
await action("hosts", "Add Host…", "server.addServer")
await dispatch("hosts", "lab")
await action("hosts", "New chat on selected host", "palette.newAgentChat", { host: "lab" })
const localSearch = "Find a session on this host"
const allSearch = "Search sessions, hosts or folders"
await dispatch("hosts", localSearch, "edit", { text: "build" })
await dispatch("tab", allSearch, "edit", { text: "draft" })
assert.ok(!nodeIn("hosts", "Local draft") && !nodeIn("tab", "Remote build"))
await action("hosts", localSearch, "agent.openSessionTab", { session: "same-id", host: "lab" }, "submit")
await action("tab", allSearch, "agent.openSessionTab", { session: "same-id" }, "submit")
await dispatch("tab", allSearch, "edit", { text: "" })
await dispatch("tab", "Show activity")
assert.ok(nodeIn("tab", "Remote build") && !nodeIn("tab", "Local draft"))
await dispatch("hosts", "Show activity")
assert.ok(nodeIn("hosts", "Working") && nodeIn("hosts", "Remote build") && !nodeIn("hosts", "Local draft"))
assert.ok(!nodeIn("hosts", "Add Host…") && !nodeIn("hosts", "Done"))
await action("hosts", "Remote build", "agent.openSessionTab", { session: "same-id", host: "lab" })
await dispatch("hosts", "By priority")
assert.ok(nodeIn("hosts", "By project") && nodeIn("hosts", "lab"))
await dispatch("hosts", "Show hosts")
assert.ok(nodeIn("hosts", "Add Host…"))
assert.equal(listReads(), 1)
host.global.__cmuxAppUnmount("hosts")
await host.settle()
assert.equal(host.subscriptions.size, 1)
chats = [{ id: "new", title: "New remote chat", state: "input", machine: "lab" }]
host.emit("agent_chat.changed")
await host.settle()
assert.equal(listReads(), 2)
assert.ok(nodeIn("tab", "New remote chat"))
host.handlers["agent_chat.list"] = () => ({ ok: false, body: { message: "Disconnected" } })
host.emit("agent_chat.changed")
await host.settle()
assert.ok(nodeIn("tab", "Retry"))
assert.ok(!nodeIn("tab", "New remote chat"))
host.handlers["agent_chat.list"] = () => ok({ chats: [] })
await dispatch("tab", "Retry")
assert.ok(nodeIn("tab", "No sessions yet"))
host.global.__cmuxAppUnmount("tab")
await host.settle()
assert.equal(host.subscriptions.size, 0)
assert.equal(host.timers.size, 0)
mount("again", "cmux.section/1")
await host.settle()
assert.equal(host.subscriptions.size, 1)
assert.deepEqual(host.logs.filter(([level]) => level === "error"), [])
console.log("Passed both exports, creation actions, independent searches, cross-host IDs, activity, retry and subscription lifetime.")
