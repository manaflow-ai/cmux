// The New Tab launcher example in the fake host. It exercises the public SDK path used by
// `cmux ext dev`, including live lists, the selected layout and actions from a tap.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const root = join(import.meta.dir, "../../../../..")
const dir = join(root, "examples/extensions/newtab-launcher")
const ok = (value: unknown) => ({ ok: true, body: { value } })

let built = ""
beforeAll(async () => {
  built = await pack(dir)
})

const chat = (id: string, title: string, state: string, preview: string | null) => ({
  id, title, state, unread: false, harness: "claude", project: "cmux", cwd: "/src/cmux", workspace: null,
  machine: null, updated_ms: 1_000, preview
})

function host(settings: Record<string, unknown> = {}) {
  const h = new FakeHost(built, { app: { id: "local/showcase-newtab-launcher", version: "1.0.0" }, settings })
  h.handlers["workspace.list"] = () => ok([
    { id: "ws-1", session_id: "s", name: "cmux", index: 0, focused: true },
    { id: "ws-2", session_id: "s", name: "docs", index: 1, focused: false }
  ])
  h.handlers["agent_chat.list"] = () => ok({ chats: [
    chat("c-1", "Fix the build", "working", "Running the suite"),
    chat("c-2", "Review the changes", "input", "What do you think?"),
    chat("c-3", "Update the docs", "idle", "Done"),
    chat("c-4", "Old chat", "idle", "Older")
  ] })
  h.handlers["action.run"] = () => ok(null)
  h.handlers["workspace.focus"] = () => ok(null)
  return h
}

function texts(h: FakeHost): string[] {
  return [...h.tree("n").nodes.values()]
    .filter((node) => node.type === "Text")
    .map((node) => String(node.props.text))
}

function rowTitles(h: FakeHost): string[] {
  return [...h.tree("n").nodes.values()]
    .filter((node) => node.type === "Row")
    .map((node) => String(node.props.title))
}

describe("local/showcase-newtab-launcher", () => {
  test("imports only the public SDK and names a whole New Tab page", () => {
    const source = readFileSync(join(dir, "src/main.ts"), "utf8")
    expect([...source.matchAll(/from\s+"([^"]+)"/g)].map((m) => m[1])).toEqual(["cmux-extension-sdk"])
    const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
    expect(manifest.implements["cmux.newtab/1"].export).toBe("renderNewTab")
    expect(manifest.variants[0].values).toEqual(["focus", "split", "compact"])
  })

  test("draws the clock, live workspaces and recent chats, and runs an action from a tap", async () => {
    const h = host({ layout: "focus", showGreeting: true, recentLimit: 3 })
    expect(h.mount("n", "renderNewTab", { surface: "newTab", cwd: "/src/cmux" })).toBe("")
    await h.settle(10)

    expect(texts(h)).toEqual(expect.arrayContaining(["A fresh tab in cmux", "Start something", "Recent chats", "Workspaces"]))
    expect(texts(h).some((text) => ["A quiet night for a fresh start", "Good morning", "Good afternoon", "Good evening"].includes(text))).toBe(true)
    expect(rowTitles(h)).toEqual(expect.arrayContaining(["Fix the build", "Review the changes", "Update the docs"]))
    expect(rowTitles(h)).not.toContain("Old chat")
    expect(h.calls.filter((call) => call.name === "agent_chat.list").map((call) => call.params)).toEqual([{ limit: 8 }])
    expect(h.timers.size).toBe(1)

    const button = h.findNode("n", (node) => node.type === "Button")!
    h.dispatch("n", button, "tap", { gesture: "g1" })
    await h.settle()
    expect(h.calls.find((call) => call.name === "action.run")?.params).toEqual({ id: "palette.newAgentChat", args: {} })
  })
})
