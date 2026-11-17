import { describe, expect, test } from "bun:test"
import { DEV_PLATFORM, SocketGate, RpcError, paneFile, paneUrl, parseArgs, plainId, plainReason, publicKeyParam, refusal, replyCarries } from "./web-device-demo.ts"

const tick = () => new Promise((r) => setTimeout(r, 0))

describe("paneUrl", () => {
  test("opens the hub chat under the daemon's own origin, with must", () => {
    const url = new URL(paneUrl(47999, "tok", "ci-join-1/0123-abcd"))
    expect(url.origin).toBe("http://127.0.0.1:47999")
    expect(url.pathname).toBe("/agent-pane/index.html")
    const f = new URLSearchParams(url.hash.slice(1))
    expect(f.get("endpoint")).toBe("ws://127.0.0.1:47999/")
    expect(f.get("token")).toBe("tok")
    expect(f.get("session")).toBe("ci-join-1/0123-abcd")
    expect(f.has("must")).toBe(true)
  })
})

describe("paneFile", () => {
  test("maps pane paths into the bundle and nothing outside it", () => {
    expect(paneFile("/b", "/agent-pane/")).toBe("/b/index.html")
    expect(paneFile("/b", "/agent-pane/chunks/x.js")).toBe("/b/chunks/x.js")
    expect(paneFile("/b", "/agent-pane/../etc/passwd")).toBeNull()
    expect(paneFile("/b", "/agent-pane/%2e%2e/secret")).toBeNull()
    expect(paneFile("/b", "/agent-pane/%E0%A4%A")).toBeNull()
    expect(paneFile("/b", "/other/index.html")).toBeNull()
  })
})

describe("SocketGate", () => {
  const setup = (ready: (g: SocketGate) => Promise<void>) => {
    const server: string[] = []
    const page: string[] = []
    const gate = new SocketGate((t) => server.push(t), (t) => page.push(t), ready, undefined, "h")
    return { gate, server, page }
  }

  test("holds the pane's frames after initialize until the harness's hello is answered", async () => {
    const { gate, server, page } = setup(async (g) => {
      await g.request("_acpmux/device_hello", { credential: "c" })
    })
    gate.fromPage(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }))
    gate.fromPage(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "_acpmux/attach", params: { sessionId: "h/s" } }))
    expect(server.map((s) => JSON.parse(s).method)).toEqual(["initialize"])
    gate.fromServer(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }))
    expect(page).toHaveLength(1)
    expect(JSON.parse(server[1]!)).toMatchObject({ id: "h-1", method: "_acpmux/device_hello" })
    expect(gate.open).toBe(false)
    // The hello's answer goes to the harness only; then the held attach goes through.
    gate.fromServer(JSON.stringify({ jsonrpc: "2.0", id: "h-1", result: {} }))
    await tick()
    expect(page).toHaveLength(1)
    expect(gate.open).toBe(true)
    expect(JSON.parse(server[2]!).method).toBe("_acpmux/attach")
    gate.fromPage(JSON.stringify({ jsonrpc: "2.0", id: 3, method: "session/prompt" }))
    expect(server).toHaveLength(4)
  })

  test("a refused hello still lets the pane's frames through and records the failure", async () => {
    const { gate, server } = setup(async (g) => {
      await g.request("_acpmux/device_hello", {})
    })
    gate.fromPage(JSON.stringify({ id: 1, method: "initialize" }))
    gate.fromPage(JSON.stringify({ id: 2, method: "_acpmux/attach" }))
    gate.fromServer(JSON.stringify({ id: 1, result: {} }))
    gate.fromServer(JSON.stringify({ id: "h-1", error: { code: -32002, message: "no <b>device</b>" } }))
    await tick()
    expect(gate.open).toBe(true)
    expect(gate.failure).toBeInstanceOf(RpcError)
    expect((gate.failure as RpcError).code).toBe(-32002)
    expect((gate.failure as RpcError).message).not.toContain("<")
    expect(server.map((s) => JSON.parse(s).method)).toEqual(["initialize", "_acpmux/device_hello", "_acpmux/attach"])
  })

  test("a closed socket fails the requests still waiting", async () => {
    const { gate } = setup(async () => undefined)
    const waiting = gate.request("_acpmux/device_enroll", {})
    gate.closed()
    await expect(waiting).rejects.toBeInstanceOf(RpcError)
  })
})

describe("replyCarries", () => {
  const update = (kind: string, text: string) => ({ jsonrpc: "2.0", method: "session/update", params: { sessionId: "s", update: { sessionUpdate: kind, content: { type: "text", text } } } })
  test("only the agent's chunk with the nonce counts, never the person's own prompt", () => {
    expect(replyCarries(update("agent_message_chunk", "Hello wd-1"), "wd-1")).toBe(true)
    expect(replyCarries(update("user_message_chunk", "Hello wd-1"), "wd-1")).toBe(false)
    expect(replyCarries(update("agent_message_chunk", "Hello"), "wd-1")).toBe(false)
    expect(replyCarries({ id: 3, result: { stopReason: "end_turn" } }, "wd-1")).toBe(false)
  })
})

describe("inputs", () => {
  const ok = { origin: DEV_PLATFORM, acpmux: "/b/acpmux", pane: "/p", target: "ci-join-9/01a1e78d-8278", name: "ci-join-9-web", label: "ci-join-9-2", out: "/o" }
  test("parseArgs and refusal", () => {
    expect(parseArgs(["--origin", DEV_PLATFORM, "--target", "h/s"]).target).toBe("h/s")
    expect(refusal(ok)).toBeUndefined()
    expect(refusal({ ...ok, origin: "https://example.invalid" })).toContain("origin")
    expect(refusal({ ...ok, target: "h/s/x" })).toContain("target")
    expect(refusal({ ...ok, target: "h" })).toContain("target")
    expect(refusal({ ...ok, pane: "rel" })).toContain("pane")
    expect(refusal({ ...ok, label: "web" })).toContain("label")
  })
  test("ids and reasons stay plain", () => {
    expect(plainId("cmm_abc")).toBeNull()
    expect(plainId("eyJhbGc")).toBeNull()
    expect(plainId("01a1e78d-8278")).toBe("01a1e78d-8278")
    expect(plainReason("a\n::error::b <x>")).toBe("a : :error: :b x")
    expect(publicKeyParam({ kty: "EC", crv: "P-256", x: "x", y: "y", d: "secret" } as any)).toEqual({ kty: "EC", crv: "P-256", x: "x", y: "y" })
    expect(() => publicKeyParam({ kty: "RSA" })).toThrow()
  })
})
