// S4 of the AutoCloud slice (auto-journey-s4.ts): the phone's read and sends to a chat the Auto machine holds, with the
// Mac asleep. A fake store stands in for /v1/auto-sessions: it numbers inbox posts (the same id is the same message),
// and a fake machine acks each message and answers it `side=vm` on the next wait. No network, no secret.
import { describe, expect, it } from "bun:test"
import { leg, percentile, phoneSends, ranLines, s4Detail, s4Text, type S4Deps } from "./auto-journey-s4.ts"

type Fake = { holder: string; dropAnswers?: boolean; doubleRun?: boolean; dupNewMessage?: boolean; refuseInbox?: boolean }

function fakeStore(f: Fake) {
  let clock = 0
  const ids = new Map<string, number>()
  const events: Array<{ seq: number; record: unknown }> = [{ seq: 1, record: { kind: "turn_result", text: "side=mac prompt=mac-1" } }]
  const s = { holder: f.holder, version: 1, lastSeq: 1, inbox: 0, inboxAcked: 0 }
  const ran: string[] = []
  const pending: Array<{ n: number; text: string }> = []
  const deps: S4Deps = {
    now: () => clock,
    sleep: async (ms) => { clock += ms },
    ranOnMachine: async () => ran.join("\n") + "\n",
    store: async (method, route, body) => {
      clock += 7
      if (method === "GET" && /\/wait\?/.test(route)) {
        clock += 40
        const m = pending.shift()
        if (m) {
          s.inboxAcked = m.n
          if (!f.dropAnswers) {
            for (let k = 0; k < (f.doubleRun ? 2 : 1); k++) {
              ran.push(`side=vm prompt=${m.text} `)
              events.push({ seq: ++s.lastSeq, record: { kind: "agent_message", text: `AUTO_JOURNEY_REPLY side=vm prompt=${m.text} ` } })
            }
          }
          s.version++
        }
        return { status: 200, body: { session: { ...s } } }
      }
      if (method === "GET" && /\/events\?/.test(route)) {
        const after = Number(/after=(\d+)/.exec(route)![1])
        return { status: 200, body: { events: events.filter((e) => e.seq > after), lastSeq: s.lastSeq } }
      }
      if (method === "GET") return { status: 200, body: { session: { ...s } } }
      if (method === "POST" && route.endsWith("/inbox")) {
        if (f.refuseInbox) return { status: 409, body: { error: { code: "auto.closed" } } }
        const { id, text } = body as { id: string; text: string }
        if (ids.has(id) && !f.dupNewMessage) return { status: 200, body: { state: "delivered", session: { ...s, inbox: ids.get(id) } } }
        s.inbox++
        ids.set(id, s.inbox)
        pending.push({ n: s.inbox, text })
        s.version++
        return { status: 200, body: { state: "delivered", session: { ...s } } }
      }
      return { status: 404, body: {} }
    },
  }
  return { deps, ran }
}

describe("S4 phone sends", () => {
  it("measures every send's post, ack and answer, and passes when each ran once on the machine", async () => {
    const { deps, ran } = fakeStore({ holder: "vm:m1" })
    const r = await phoneSends(deps, "chat-1", "m1", "aj-t", 20)
    expect(r.why).toBe("")
    expect(r.ok).toBe(true)
    expect(r.n).toBe(20)
    expect(r.samples).toHaveLength(20)
    expect(ran).toHaveLength(20)
    for (const s of r.samples) {
      expect(s.postMs).toBeGreaterThan(0)
      expect(s.ackMs).toBeGreaterThanOrEqual(s.postMs)
      expect(s.turnMs).toBeGreaterThanOrEqual(s.postMs)
    }
    expect(r.post && r.ack && r.turn).toBeTruthy()
    expect(s4Detail(r)).toMatch(/^n 20; read \d+ ms; post p50 [\d.]+ p99 [\d.]+ ms; ack p50 .*; vm answer p50 /)
  })

  it("fails when the phone reads a holder that is not the Auto machine", async () => {
    const { deps } = fakeStore({ holder: "device:mac" })
    const r = await phoneSends(deps, "chat-1", "m1", "aj-t", 3)
    expect(r.ok).toBe(false)
    expect(r.why).toContain("holder device:mac, not vm:m1")
    expect(r.n).toBe(0)
  })

  it("fails when the same id posted twice becomes two messages", async () => {
    const { deps } = fakeStore({ holder: "vm:m1", dupNewMessage: true })
    const r = await phoneSends(deps, "chat-1", "m1", "aj-t", 3)
    expect(r.ok).toBe(false)
    expect(r.why).toContain("taken as two messages")
  })

  it("fails when a send runs twice on the machine, keeping the numbers it got", async () => {
    const { deps } = fakeStore({ holder: "vm:m1", doubleRun: true })
    const r = await phoneSends(deps, "chat-1", "m1", "aj-t", 4)
    expect(r.ok).toBe(false)
    expect(r.why).toBe("send 1 ran 2 times on the machine, not once")
    expect(r.n).toBe(4)
    expect(r.turn?.p50).toBeGreaterThan(0)
  })

  it("fails a send the machine never answers, within its budget", async () => {
    const { deps } = fakeStore({ holder: "vm:m1", dropAnswers: true })
    const r = await phoneSends(deps, "chat-1", "m1", "aj-t", 2)
    expect(r.ok).toBe(false)
    expect(r.why).toMatch(/^send 1 \(aj-t-s4-1\): never answered side=vm in 120 s$/)
  })

  it("names a refused inbox post", async () => {
    const { deps } = fakeStore({ holder: "vm:m1", refuseInbox: true })
    const r = await phoneSends(deps, "chat-1", "m1", "aj-t", 2)
    expect(r.why).toContain("send 1: inbox HTTP 409")
  })
})

describe("S4 helpers", () => {
  it("takes nearest-rank percentiles", () => {
    const xs = Array.from({ length: 100 }, (_, i) => i + 1)
    expect(percentile(xs, 50)).toBe(50)
    expect(percentile(xs, 99)).toBe(99)
    expect(percentile([5], 99)).toBe(5)
    expect(leg([])).toBeNull()
    expect(leg([3, 1, 2])).toEqual({ p50: 2, p99: 3, max: 3 })
  })

  it("never counts one send's line as another's", () => {
    expect(s4Text(1)).toBe("s4-1-end")
    const ran = `side=vm prompt=s4-11-end \nside=vm prompt=s4-1-end \nside=mac prompt=s4-1-end \n`
    expect(ranLines(ran, s4Text(1))).toBe(1)
    expect(ranLines(ran, s4Text(11))).toBe(1)
    expect(ranLines(ran, s4Text(2))).toBe(0)
  })
})
