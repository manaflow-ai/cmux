import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "./fake-host.ts"
const code = () => readFileSync(join(import.meta.dir, "../../../../../samples/apps/agent-board/dist/main.js"), "utf8")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const post = { id: "p1", kind: "warn", body: "Queued past 30 minutes", created: 1795158180000, sources: { "host-a": { id: "a" }, "host-b": { id: "b" } } }
const thread = { channel: "ops/runner-capacity", thread: "ubuntu-24", latest: post, posts: [post] }
function board() {
  const host = new FakeHost(code(), { app: { id: "manaflow-ai/agent-board", version: "1.0.0" }, settings: {} })
  host.handlers["agent_chat.list"] = () => ok({ chats: [{ id: "s", title: "Coordinator" }, { id: "remote", title: "Remote", machine: "peer" }] })
  host.handlers["forum.threads"] = () => ok({ recipient: "s", threads: [thread] })
  return host
}
function tap(host: FakeHost, title: string) {
  const node = host.findNode("m", (n) => n.type === "Row" && n.props.title === title)!
  host.dispatch("m", node, "tap", { gesture: "g1" })
}
const nodes = (host: FakeHost) => [...host.tree("m").nodes.values()]

describe("Board Store pane", () => {
  test("selects an explicit local recipient and renders one thread with both host sources", async () => {
    const host = board()
    expect(host.mount("m", "renderPane")).toBe("")
    await host.settle()
    expect(nodes(host).filter((n) => n.type === "Row").map((n) => n.props.title)).toEqual(["Coordinator"])
    tap(host, "Coordinator")
    await host.settle()
    expect(host.calls.filter((c) => c.name === "forum.threads").map((c) => c.params)).toEqual([{ sessionId: "s" }])
    tap(host, "ubuntu-24")
    await host.settle()
    expect(host.calls.filter((c) => c.name === "forum.threads").at(-1)!.params).toEqual({ sessionId: "s", channel: "ops/runner-capacity", thread: "ubuntu-24" })
    expect(JSON.stringify(nodes(host))).toContain("host-a · host-b")
    expect(JSON.stringify(nodes(host))).toContain("Queued past 30 minutes")
    expect(host.timers.size).toBe(0)
  })

  test("revoked access clears previously displayed thread bodies", async () => {
    const host = board()
    host.mount("m", "renderPane")
    await host.settle()
    tap(host, "Coordinator")
    await host.settle()
    tap(host, "ubuntu-24")
    await host.settle()
    expect(JSON.stringify(nodes(host))).toContain(post.body)
    host.handlers["forum.threads"] = () => ({ ok: false, body: { code: "scope.missing", message: "denied" } })
    host.dispatch("m", host.findNode("m", (n) => n.type === "Button" && n.props.title === "Refresh")!, "tap", { gesture: "g2" })
    await host.settle()
    expect(nodes(host).find((n) => n.type === "EmptyState")!.props.title).toBe("Board unavailable")
    expect(JSON.stringify(nodes(host))).not.toContain(post.body)
  })

  test("paginates thread rows and combines source fragments without duplicating a post", async () => {
    const host = board()
    host.handlers["forum.threads"] = (params) => {
      if (!params.thread) return ok({ recipient: "s", threads: params.cursor
        ? [thread, { ...thread, thread: "ubuntu-22" }] : [thread], nextCursor: params.cursor ? null : "threads-2" })
      const sources = params.cursor ? ["host-c"] : ["host-a", "host-b"]
      return ok({ recipient: "s", threads: sources.map((source) => ({ ...thread, posts: [{ ...post, sourceCount: 3, sources: { [source]: { receipt: source } } }] })), nextCursor: params.cursor ? null : "sources-2" })
    }
    host.mount("m", "renderPane")
    await host.settle()
    tap(host, "Coordinator")
    await host.settle()
    const more = () => host.dispatch("m", host.findNode("m", (n) => n.type === "Button" && n.props.title === "Load more")!, "tap", { gesture: "more" })
    more()
    await host.settle()
    expect(nodes(host).filter((n) => n.type === "Row").map((n) => n.props.title)).toEqual(["ubuntu-24", "ubuntu-22"])
    expect(host.calls.filter((c) => c.name === "forum.threads").at(-1)!.params).toEqual({ sessionId: "s", cursor: "threads-2" })
    tap(host, "ubuntu-24")
    await host.settle()
    expect(JSON.stringify(nodes(host))).toContain("Sources 2/3")
    more()
    await host.settle()
    const scene = JSON.stringify(nodes(host))
    expect(scene).toContain("Sources 3/3: host-a · host-b · host-c")
    expect(scene.split(post.body).length - 1).toBe(1)
    expect(host.calls.filter((c) => c.name === "forum.threads").at(-1)!.params).toEqual({ sessionId: "s", channel: "ops/runner-capacity", thread: "ubuntu-24", cursor: "sources-2" })
    expect(nodes(host).some((n) => n.type === "Button" && n.props.title === "Load more")).toBe(false)
  })

  test("an empty recipient has an explicit empty state", async () => {
    const host = board()
    host.handlers["forum.threads"] = () => ok({ recipient: "s", threads: [] })
    host.mount("m", "renderPane")
    await host.settle()
    tap(host, "Coordinator")
    await host.settle()
    expect(nodes(host).find((n) => n.type === "EmptyState")!.props.title).toBe("No work threads yet")
  })
})
