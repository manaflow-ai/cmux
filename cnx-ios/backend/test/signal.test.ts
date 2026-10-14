import { describe, expect, it } from "vitest"
import { BUCKETS, uuidToBytes } from "../src/team-hub.ts"
import { call, connect, PROD_PROJECT, register, token, worker } from "./helpers.ts"

const offer = (from: string, to: string, sessionId = crypto.randomUUID()) => ({ type: "signal", to, from, sessionId, payload: { kind: "webrtc-offer", sdp: "v=0" } })

describe("TeamHub signaling", () => {
  it("refuses sockets without auth, membership or a registered own device", async () => {
    const alice = await token("alice")
    const mac = await register(alice, "mac", "team-a")
    const up = { Upgrade: "websocket" }
    expect((await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${mac}`, { headers: up })).status).toBe(401)
    const asBob = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${mac}`, { headers: { ...up, authorization: `Bearer ${await token("bob")}` } })
    expect(asBob.status).toBe(403)
    const asMallory = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${mac}`, { headers: { ...up, authorization: `Bearer ${await token("mallory")}` } })
    expect(asMallory.status).toBe(403)
    const unknown = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${crypto.randomUUID()}`, { headers: { ...up, authorization: `Bearer ${alice}` } })
    expect(unknown.status).toBe(403)
  })

  it("admits a device only in the team it is registered in, also after it moved", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a", "Alice iPhone")
    const up = { Upgrade: "websocket", authorization: `Bearer ${alice}` }
    const first = await connect(alice, "team-a", phone)
    first.ws.close()
    expect((await call("POST", "/v1/devices", alice, { deviceId: phone, kind: "phone", name: "Alice iPhone", teamId: "personal-alice" })).status).toBe(200)
    // The old team's hub forgot it; the database says it lives elsewhere now.
    const stale = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${phone}`, { headers: up })
    expect(stale.status).toBe(403)
    const moved = await connect(alice, "personal-alice", phone)
    moved.ws.close()
  })

  it("sends hello and broadcasts Mac presence on connect and disconnect", async () => {
    const team = "team-a"
    const alice = await token("alice")
    const phone = await register(alice, "phone", team)
    const mac = await register(alice, "mac", team, "Presence Mac")
    const p = await connect(alice, team, phone, true)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(p.frames[0]).toMatchObject({ type: "hello", you: phone })
    expect(p.frames[0].macs.find((m: any) => m.deviceId === mac)).toMatchObject({ online: false })
    const m = await connect(alice, team, mac)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    expect(p.frames.find((f) => f.type === "presence")!.mac).toMatchObject({ deviceId: mac, name: "Presence Mac", online: true })
    const listed = await call("GET", `/v1/teams/${team}/macs`, alice)
    expect(listed.json.macs.find((x: any) => x.deviceId === mac)).toMatchObject({ online: true })
    m.ws.close(1000, "done")
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && !f.mac.online))
    expect(p.frames.filter((f) => f.type === "presence").at(-1)!.mac.lastSeenAt).toEqual(expect.any(String))
    p.ws.close()
  })

  it("forwards signals to an owned Mac, the reply direction, and refuses other owners", async () => {
    const team = "team-a"
    const alice = await token("alice")
    const bob = await token("bob")
    const phone = await register(alice, "phone", team)
    const mac = await register(alice, "mac", team)
    const bobPhone = await register(bob, "phone", team)
    const p = await connect(alice, team, phone)
    const m = await connect(alice, team, mac)
    const bp = await connect(bob, team, bobPhone)
    for (const s of [p, m, bp]) await s.until((x) => x.frames.some((f) => f.type === "hello"))

    const sessionId = crypto.randomUUID()
    p.send(offer(phone, mac, sessionId))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal")).toEqual({ type: "signal", to: mac, from: phone, fromUserId: "alice", sessionId, payload: { kind: "webrtc-offer", sdp: "v=0" } })

    m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "webrtc-answer", sdp: "v=0 answer" } })
    await p.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(p.frames.find((f) => f.type === "signal")).toMatchObject({ from: mac, fromUserId: "alice", payload: { kind: "webrtc-answer" } })

    // Bob is in the team but does not own the Mac.
    bp.send(offer(bobPhone, mac))
    await bp.until((s) => s.frames.some((f) => f.type === "error"))
    expect(bp.frames.find((f) => f.type === "error")).toMatchObject({ code: "not_owner" })
    // Bob cannot ride Alice's session either.
    bp.send({ ...offer(bobPhone, mac, sessionId) })
    await bp.until((s) => s.frames.filter((f) => f.type === "error").length >= 2)
    // The Mac cannot start a session to a phone.
    m.send(offer(mac, bobPhone))
    await m.until((s) => s.frames.some((f) => f.type === "error"))
    expect(m.frames.find((f) => f.type === "error")).toMatchObject({ code: "not_owner" })
    // Spoofed `from` is refused.
    p.send(offer(bobPhone, mac))
    await p.until((s) => s.frames.some((f) => f.type === "error"))
    expect(p.frames.find((f) => f.type === "error")).toMatchObject({ code: "bad_request" })
    expect(m.frames.filter((f) => f.type === "signal")).toHaveLength(1)
    for (const s of [p, m, bp]) s.ws.close()
  })

  it("overwrites a client-supplied fromUserId with the verified sender", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    const m = await connect(alice, "team-a", mac)
    await m.until((s) => s.frames.some((f) => f.type === "hello"))
    p.send({ ...offer(phone, mac), fromUserId: "mallory" })
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal").fromUserId).toBe("alice")
    for (const s of [p, m]) s.ws.close()
  })

  it("personal space signals and relays for its owner only", async () => {
    const solo = await token("solo")
    const team = "personal-solo"
    const phone = await register(solo, "phone", team)
    const mac = await register(solo, "mac", team)
    const p = await connect(solo, team, phone)
    const m = await connect(solo, team, mac)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    const sessionId = crypto.randomUUID()
    p.send(offer(phone, mac, sessionId))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal")).toMatchObject({ from: phone, fromUserId: "solo" })
    const b = new Uint8Array(36)
    b.set(uuidToBytes(sessionId), 0)
    b.set(uuidToBytes(mac), 16)
    p.ws.send(b)
    await m.until((s) => s.binary.length === 1)
    expect([...m.binary[0]!.subarray(16, 32)]).toEqual([...uuidToBytes(phone)])
    const alicePhone = await register(await token("alice"), "phone", "team-a")
    const other = await worker.fetch(`https://api.test/v1/teams/${team}/signal?deviceId=${alicePhone}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${await token("alice")}` } })
    expect(other.status).toBe(403)
    for (const s of [p, m]) s.ws.close()
  })

  it("reports an offline Mac", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    p.send(offer(phone, mac))
    await p.until((s) => s.frames.some((f) => f.type === "error"))
    expect(p.frames.find((f) => f.type === "error")).toMatchObject({ code: "offline" })
    p.ws.close()
  })

  it("relays WireGuard frames for a session and rewrites the to field to the sender", async () => {
    const alice = await token("alice")
    const bob = await token("bob")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const bobPhone = await register(bob, "phone", "team-a")
    const p = await connect(alice, "team-a", phone)
    const m = await connect(alice, "team-a", mac)
    const bp = await connect(bob, "team-a", bobPhone)
    for (const s of [p, m, bp]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((s) => s.frames.some((f) => f.type === "signal"))

    const frame = (to: string, sid = sessionId) => {
      const b = new Uint8Array(32 + 4)
      b.set(uuidToBytes(sid), 0)
      b.set(uuidToBytes(to), 16)
      b.set([1, 2, 3, 4], 32)
      return b
    }
    p.ws.send(frame(mac))
    await m.until((s) => s.binary.length === 1)
    const got = m.binary[0]!
    expect([...got.subarray(0, 16)]).toEqual([...uuidToBytes(sessionId)])
    expect([...got.subarray(16, 32)]).toEqual([...uuidToBytes(phone)])
    expect([...got.subarray(32)]).toEqual([1, 2, 3, 4])

    m.ws.send(frame(phone))
    await p.until((s) => s.binary.length === 1)
    expect([...p.binary[0]!.subarray(16, 32)]).toEqual([...uuidToBytes(mac)])

    // A device outside the session cannot inject frames, and a burst of refused frames gets one error.
    for (let i = 0; i < 10; i++) bp.ws.send(frame(mac))
    await bp.until((s) => s.frames.some((f) => f.type === "error" && f.code === "not_owner"))
    p.send({ type: "nope" })
    await p.until((s) => s.frames.some((f) => f.type === "error" && f.code === "bad_request"))
    bp.send({ type: "nope" })
    await bp.until((s) => s.frames.some((f) => f.type === "error" && f.code === "bad_request"))
    expect(bp.frames.filter((f) => f.type === "error" && f.code === "not_owner")).toHaveLength(1)
    expect(bp.frames.find((f) => f.code === "not_owner")).toMatchObject({ sessionId })
    expect(m.binary).toHaveLength(1)
    for (const s of [p, m, bp]) s.ws.close()
  })

  it("relays a burst of frames in order, with room for about 100 Mbit/s", async () => {
    const solo = await token("burst")
    const team = "personal-burst"
    const phone = await register(solo, "phone", team)
    const mac = await register(solo, "mac", team)
    const p = await connect(solo, team, phone)
    const m = await connect(solo, team, mac)
    for (const s of [p, m]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(BUCKETS.binary.burst).toBeGreaterThanOrEqual(20000)
    const count = 2000
    const b = new Uint8Array(32 + 40)
    b.set(uuidToBytes(sessionId), 0)
    b.set(uuidToBytes(mac), 16)
    for (let i = 0; i < count; i++) {
      b[32] = i & 0xff
      b[33] = i >> 8
      p.ws.send(b)
    }
    const deadline = Date.now() + 20000
    while (m.binary.length < count && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50))
    expect(m.binary.length).toBe(count)
    expect(m.binary.every((f, i) => f[32] === (i & 0xff) && f[33] === i >> 8)).toBe(true)
    for (const s of [p, m]) s.ws.close()
  }, 30000)

  it("reports where a team's hub runs", async () => {
    const alice = await token("alice")
    const r = await call("GET", "/v1/teams/team-a/hub", alice)
    expect(r.status).toBe(200)
    expect(r.json).toHaveProperty("hubColo")
    expect(r.json).toHaveProperty("ingressColo")
    expect((await call("GET", "/v1/teams/team-a/hub", await token("mallory"))).status).toBe(403)
  })

  it("a reconnect replaces the old socket without an offline blip", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    const m1 = await connect(alice, "team-a", mac)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    const m2 = await connect(alice, "team-a", mac)
    await m1.until((s) => s.closed)
    p.send(offer(phone, mac))
    await m2.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(p.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && !f.mac.online)).toBe(false)
    for (const s of [p, m2]) s.ws.close()
  })

  it("production users signal their own Macs; the same sub in dev cannot", async () => {
    const pat = await token("pat", { project: PROD_PROJECT })
    const phone = await register(pat, "phone", "team-p")
    const mac = await register(pat, "mac", "team-p")
    const p = await connect(pat, "team-p", phone, true)
    const m = await connect(pat, "team-p", mac)
    await m.until((s) => s.frames.some((f) => f.type === "hello"))
    p.send(offer(phone, mac))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal")).toMatchObject({ from: phone, fromUserId: "pat" })

    // Dev alice and prod alice share a sub and the id personal-alice, not a space.
    const prodAlice = await token("alice", { project: PROD_PROJECT })
    const devAlice = await token("alice")
    const prodMac = await register(prodAlice, "mac", "personal-alice")
    const devPhone = await register(devAlice, "phone", "personal-alice")
    const pm = await connect(prodAlice, "personal-alice", prodMac)
    const dp = await connect(devAlice, "personal-alice", devPhone)
    await dp.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(dp.frames[0].macs.map((x: any) => x.deviceId)).not.toContain(prodMac)
    dp.send(offer(devPhone, prodMac))
    await dp.until((s) => s.frames.some((f) => f.type === "error"))
    expect(dp.frames.find((f) => f.type === "error")).toMatchObject({ code: "not_owner" })
    expect(pm.frames.some((f) => f.type === "signal")).toBe(false)
    // Nor can the dev user open a socket as the prod device.
    const asDev = await worker.fetch(`https://api.test/v1/teams/personal-alice/signal?deviceId=${prodMac}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${devAlice}` } })
    expect(asDev.status).toBe(403)
    for (const s of [p, m, pm, dp]) s.ws.close()
  })
})
