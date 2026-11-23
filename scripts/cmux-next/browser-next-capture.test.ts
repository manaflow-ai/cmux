import { expect, test } from "bun:test"
import { CaptureOracle } from "./browser-next-capture-oracle.ts"
import { boundedCleanup, validateConfig } from "./browser-next-capture.ts"

const target = "machine/chat"
const nonce = "browser-nonce"
function wire(o: CaptureOracle, socket = 1) {
  const sent = (m: unknown) => o.observe(socket, "sent", JSON.stringify(m))
  const received = (m: unknown) => o.observe(socket, "received", JSON.stringify(m))
  const attach = () => {
    sent({ id: 1, method: "_acpmux/device_hello" })
    received({ id: 1, result: { auth: "webDevice" } })
    sent({ id: 2, method: "_acpmux/attach", params: { sessionId: target } })
    received({ id: 2, result: { sessionId: "chat" } })
  }
  const prompt = () => sent({ id: 3, method: "session/prompt", params: { sessionId: target, prompt: [{ type: "text", text: nonce }] } })
  const chunk = (text: string, sessionId = target, sessionUpdate = "agent_message_chunk") =>
    received({ method: "session/update", params: { sessionId, update: { sessionUpdate, content: { type: "text", text } } } })
  return { sent, received, attach, prompt, chunk }
}

test("the browser must authenticate, attach the intended chat, send and receive a completed answer", async () => {
  const o = new CaptureOracle(target, nonce)
  const w = wire(o)
  w.attach(); w.prompt()
  const done = o.wait(() => o.replySeen && o.completed, 1000, "reply")
  w.chunk("browser-"); w.chunk("nonce")
  w.received({ id: 3, result: { stopReason: "end_turn" } })
  await done
  expect(o.summary()).toEqual({ helloCount: 1, attachCount: 1, promptSent: true, replySeen: true, completed: true })
  wire(o, 2).attach()
  expect(o.attachCount).toBe(2)
})

test("a user echo, another chat, and history before sending cannot satisfy the reply", () => {
  const o = new CaptureOracle(target, nonce)
  const w = wire(o)
  w.attach(); w.chunk(nonce)
  expect(o.replySeen).toBe(false)
  w.prompt(); w.chunk(nonce, target, "user_message_chunk"); w.chunk(nonce, "unrelated")
  expect(o.replySeen).toBe(false)
  w.chunk(nonce, "chat")
  expect(o.replySeen).toBe(true)
})

test("eventStream records count only incoming assistant chunks for the prompted socket and chat", () => {
  const o = new CaptureOracle(target, nonce)
  const a = wire(o), b = wire(o, 2)
  a.attach(); b.attach(); a.prompt()
  const event = { method: "_acpmux/event", params: { sessionId: target, seq: 10, dir: "in", kind: "agent_message_chunk",
    msg: { method: "session/update", params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: nonce } } } } } }
  b.received(event)
  a.received({ ...event, params: { ...event.params, dir: "out" } })
  a.received({ ...event, params: { ...event.params, sessionId: "other/chat" } })
  expect(o.replySeen).toBe(false)
  a.received(event)
  expect(o.replySeen).toBe(true)
})

test("a listener token or refused hello does not prove web-device access", () => {
  for (const answer of [{ result: { auth: "listenerToken" } }, { error: { code: -32003 } }]) {
    const o = new CaptureOracle(target, nonce)
    const w = wire(o)
    w.sent({ id: 1, method: "_acpmux/device_hello" }); w.received({ id: 1, ...answer })
    w.sent({ id: 2, method: "_acpmux/attach", params: { sessionId: target } }); w.received({ id: 2, result: {} })
    w.prompt(); w.chunk(nonce)
    expect(o.attachCount).toBe(0)
    expect(o.replySeen).toBe(false)
  }
})

test("socket request ids cannot authenticate or attach another connection", () => {
  const o = new CaptureOracle(target, nonce)
  const a = wire(o, 1), b = wire(o, 2)
  a.sent({ id: 1, method: "_acpmux/device_hello" })
  b.received({ id: 1, result: { auth: "webDevice" } })
  expect(o.helloCount).toBe(0)
  a.attach()
  b.sent({ id: 2, method: "_acpmux/attach", params: { sessionId: target } }); b.received({ id: 2, result: {} })
  expect(o.attachCount).toBe(1)
})

test("a bounded wait reports its stage and removes its observer", async () => {
  const o = new CaptureOracle(target, nonce)
  await expect(o.wait(() => false, 1, "device-attach")).rejects.toThrow("device-attach")
  expect(o.listenerCount("change")).toBe(0)
})

test("hung video or browser cleanup returns failure so the receipt can be persisted", async () => {
  expect(await boundedCleanup(() => new Promise<void>(() => {}), 5)).toBe(false)
  expect(await boundedCleanup(async () => { throw new Error("closed") }, 1000)).toBe(false)
  expect(await boundedCleanup(async () => {}, 1000)).toBe(true)
})

test("config rejects stand-in agents and identities without exact artifact heads", () => {
  const c = { url: "http://127.0.0.1:4100/", websocketOrigin: "ws://127.0.0.1:4100", target,
    shellSelector: "nav", openSelectors: [], composerSelector: "textarea", replySelector: ".reply",
    sourceHead: "a".repeat(40), daemonHead: "b".repeat(40), agent: "codex" as const }
  expect(() => validateConfig(c)).not.toThrow()
  expect(() => validateConfig({ ...c, agent: "stub" as any })).toThrow("agent")
  expect(() => validateConfig({ ...c, daemonHead: "latest" })).toThrow("head")
  expect(() => validateConfig({ ...c, websocketOrigin: "ws://127.0.0.1:4100/?token=secret" })).toThrow("websocketOrigin")
})
