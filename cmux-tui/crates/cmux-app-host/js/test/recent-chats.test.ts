// cmux-extension-sdk's recentChats in the fake host: a New Tab look's recent chats are one
// `agent_chat.list` read with a limit (cmux keeps the chats in order; the app never lists every
// chat and sorts it), re-read on agent_chat.changed, and a page of All chats names the cursor of
// the page before.
import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const root = join(import.meta.dir, "../../../../..")
const sdk = join(root, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts")
const ok = (value: unknown) => ({ ok: true, body: { value } })

const MAIN = `import { ForEach, Row, VStack, newTab, recentChats, recentChatsFields } from "cmux-extension-sdk"
export const fields = recentChatsFields({ limit: 50, state: "input", after: { id: "c9", updated_ms: 900, machine: "mini" } })
export const renderNewTab = newTab(() => {
  const recent = recentChats({ limit: 3 })
  return VStack([ForEach({ items: () => recent() ?? [], key: (c) => c.id }, (c) => Row({ title: () => c().title, subtitle: () => c().preview ?? "" }))])
})
`

let dir = ""
let built = ""
beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "recent-chats-"))
  mkdirSync(join(dir, "src"))
  writeFileSync(
    join(dir, "cmux-app.json"),
    JSON.stringify({
      manifestVersion: 2,
      id: "local/recent",
      name: "Recent",
      version: "0.1.0",
      engines: { cmux: "^2.0" },
      runtime: { main: "dist/main.js" },
      implements: { "cmux.newtab/1": { export: "renderNewTab", title: "Recent" } },
      files: ["dist/"],
    }),
  )
  writeFileSync(join(dir, "src/main.ts"), MAIN)
  built = await pack(dir, { sdk })
})
afterAll(() => rmSync(dir, { recursive: true, force: true }))

const chat = (id: string, title: string, preview: string | null) => ({
  id, title, state: "idle", unread: false, harness: "claude", project: "cmux", cwd: "/src/cmux",
  workspace: null, machine: null, updated_ms: 1000, preview,
})

describe("recentChats", () => {
  test("reads the newest chats with a limit, draws them with their last reply, and re-reads on agent_chat.changed", async () => {
    const host = new FakeHost(built, { app: { id: "local/recent", version: "0.1.0" }, settings: {} })
    let chats = [chat("c1", "Fix upload", "Done: tests pass"), chat("c2", "Docs", null)]
    host.handlers["agent_chat.list"] = () => ok({ chats })
    host.mount("n", "renderNewTab", { surface: "newTab" })
    await host.settle()
    const reads = () => host.calls.filter((c) => c.name === "agent_chat.list")
    expect(reads().map((c) => c.params)).toEqual([{ limit: 3 }])
    const rows = () => [...host.tree("n").nodes.values()].filter((n) => n.type === "Row").map((n) => [n.props.title, n.props.subtitle])
    expect(rows()).toEqual([["Fix upload", "Done: tests pass"], ["Docs", ""]])
    expect(host.timers.size).toBe(0)
    chats = [chat("c3", "New", "Hi")]
    host.emit("agent_chat.changed")
    await host.settle()
    expect(reads().length).toBe(2)
    expect(rows()).toEqual([["New", "Hi"]])
  })

  test("a page after a chat names its cursor", () => {
    const host = new FakeHost(built, { app: { id: "local/recent", version: "0.1.0" }, settings: {} })
    expect(host.global.__cmuxAppExports.fields).toEqual({
      limit: 50, state: "input", before_ms: 900, before_id: "c9", before_machine: "mini",
    })
  })
})
