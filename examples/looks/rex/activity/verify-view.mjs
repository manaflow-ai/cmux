import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { FakeHost } from "../../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const read = path => readFileSync(new URL(path, import.meta.url), "utf8")
const manifest = JSON.parse(read("customize/cmux-app.json"))
const profile = JSON.parse(read("profile.json"))
for (const path of ["customize/cmux-app.json", "customize/main.js"]) assert.equal(profile.files[path], read(path))
const host = new FakeHost(read("customize/main.js"))
const ok = value => ({ ok: true, body: { value } })
let chats = [
  { id: "same-id", title: "Local draft", state: "idle", updated_ms: 1, project: "api" },
  { id: "same-id", title: "Remote build", state: "working", machine: "lab", updated_ms: 3, project: "api" },
  { id: "ask", title: "Needs a decision", state: "input", updated_ms: 2, project: "web" },
  { id: "late", title: "Finished unread", state: "idle", unread: true, updated_ms: 4, project: "web" }
]
host.handlers["agent_chat.list"] = () => ok({ chats })
host.handlers["action.run"] = () => ok({})
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
const nodeIn = (id, label) => attached(id, n => [n.props.text, n.props.title, n.props.label].includes(label))
const reads = () => host.calls.filter(c => c.name === "agent_chat.list").length
assert.equal(host.mount("side", manifest.implements["cmux.section/1"].export), "")
await host.settle()
assert.equal(reads(), 1)
assert.equal(host.subscriptions.size, 1)
for (const t of ["Needs input", "Unread", "Working", "Needs a decision", "Finished unread", "Remote build"]) assert.ok(nodeIn("side", t), t)
assert.ok(!nodeIn("side", "Local draft"), "idle hidden by default")
assert.ok(!nodeIn("side", "Done"), "unread is never called Done")
const toggle = nodeIn("side", "Include idle")
host.dispatch("side", toggle, "change", { value: true })
await host.settle()
assert.ok(nodeIn("side", "Local draft"))
const count = host.calls.length
host.dispatch("side", nodeIn("side", "Remote build"), "tap", { gesture: "tap" })
await host.settle()
assert.deepEqual(host.calls.slice(count).filter(c => c.name === "action.run").map(c => c.params),
  [{ id: "agent.openSessionTab", args: { session: "same-id", host: "lab" } }])
host.dispatch("side", nodeIn("side", "By priority"), "tap", { gesture: "tap" })
await host.settle()
assert.ok(nodeIn("side", "By project") && nodeIn("side", "api") && nodeIn("side", "web"))
chats = chats.filter(c => c.id !== "ask")
host.emit("agent_chat.changed", {})
await host.settle()
assert.equal(reads(), 2)
assert.ok(!nodeIn("side", "Needs a decision"))
host.global.__cmuxAppUnmount("side")
await host.settle()
assert.equal(host.subscriptions.size, 0)
console.log("activity view ok")
