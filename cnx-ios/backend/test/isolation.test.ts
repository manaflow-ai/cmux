import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { memoryStore } from "../src/store.ts"
import { userHubName, uuidToBytes, type TeamHub } from "../src/team-hub.ts"
import { call, connect, register, token, worker, type Sock } from "./helpers.ts"

/**
 * The hub is per user (PROTOCOL.md "Signaling WebSocket"): uma and vic are both members of team-u, and
 * neither may learn of, list, signal or reach the other's devices through any endpoint or hub message.
 */
const HEX = "cd".repeat(32)
const TEAM = "team-u"
const offer = (from: string, to: string, sessionId = crypto.randomUUID(), kind = "webrtc-offer") => ({ type: "signal", to, from, sessionId, payload: { kind, sdp: "v=0" } })
const hello = (s: Sock) => s.until((x) => x.frames.some((f) => f.type === "hello"))
const errors = (s: Sock) => s.frames.filter((f) => f.type === "error")
/** Every id and name a socket has heard, as one string to search. */
const heard = (s: Sock) => JSON.stringify(s.frames)
const hubOf = (owner: string) => (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB.get((env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB.idFromName(userHubName(owner)))

const setup = async () => {
  const uma = await token("uma")
  const vic = await token("vic")
  const umaPhone = await register(uma, "phone", TEAM, "Uma iPhone")
  const umaMac = await register(uma, "mac", TEAM, "Uma Studio")
  const vicPhone = await register(vic, "phone", TEAM, "Vic iPhone")
  const vicMac = await register(vic, "mac", TEAM, "Vic Studio")
  return { uma, vic, umaPhone, umaMac, vicPhone, vicMac }
}

describe("per-user hub isolation (two users on one team)", () => {
  it("REST: lists, bootstrap and device views show only the caller's own devices", async () => {
    const { uma, vic, umaPhone, umaMac, vicPhone, vicMac } = await setup()
    const ids = (r: { json: any }, key = "macs") => (r.json[key] as Array<{ deviceId: string }>).map((d) => d.deviceId)
    for (const [tok, own, other] of [
      [uma, [umaMac], [vicMac, vicPhone]],
      [vic, [vicMac], [umaMac, umaPhone]]
    ] as const) {
      const team = await call("GET", `/v1/teams/${TEAM}/macs`, tok)
      expect(team.status).toBe(200)
      expect(ids(team)).toEqual(expect.arrayContaining([...own]))
      for (const id of other) expect(ids(team)).not.toContain(id)
      const mine = await call("GET", "/v1/me/macs", tok)
      for (const id of other) expect(ids(mine)).not.toContain(id)
      const devices = await call("GET", "/v1/me/devices", tok)
      for (const id of other) expect(ids(devices, "devices")).not.toContain(id)
      const boot = await call("POST", "/v1/me/bootstrap", tok, { teamId: TEAM, devices: [] })
      for (const id of other) {
        expect(ids({ json: boot.json.macs })).not.toContain(id)
        expect(ids({ json: boot.json.myMacs })).not.toContain(id)
      }
    }
    // Nothing of uma's appears anywhere in vic's answers, not even her user id.
    const sub = "uma"
    for (const path of [`/v1/teams/${TEAM}/macs`, "/v1/me/macs", "/v1/me/devices"])
      expect(JSON.stringify((await call("GET", path, vic)).json)).not.toMatch(new RegExp(`${umaMac}|${umaPhone}|"${sub}"|Uma`))
  })

  it("REST: another user cannot take over, delete, push to or notify from a teammate's devices", async () => {
    const { uma, vic, umaPhone, umaMac } = await setup()
    expect(await call("POST", "/v1/devices", vic, { deviceId: umaMac, kind: "mac", name: "Mine now", teamId: TEAM })).toMatchObject({ status: 403, json: { error: { code: "not_owner" } } })
    expect(await call("DELETE", `/v1/devices/${umaMac}`, vic)).toMatchObject({ status: 403 })
    expect((await call("PUT", `/v1/devices/${umaPhone}/push`, vic, { token: HEX, environment: "sandbox", topic: "dev.cmux.cnx" })).status).toBe(403)
    expect((await call("DELETE", `/v1/devices/${umaPhone}/push`, vic)).status).toBe(403)
    expect((await call("POST", `/v1/devices/${umaMac}/notify`, vic, { eventId: "e1", kind: "question" })).status).toBe(403)
    // Uma's devices are untouched.
    const mine = (await call("GET", "/v1/me/devices", uma)).json.devices
    expect(mine.find((d: any) => d.deviceId === umaMac)).toMatchObject({ name: "Uma Studio", teamId: TEAM })
  })

  it("hub: hello and presence carry only the socket owner's Macs", async () => {
    const { uma, vic, umaPhone, umaMac, vicPhone, vicMac } = await setup()
    const vp = await connect(vic, TEAM, vicPhone)
    const vm = await connect(vic, TEAM, vicMac)
    const up = await connect(uma, TEAM, umaPhone)
    for (const s of [vp, vm, up]) await hello(s)
    expect(vp.frames[0].macs.map((m: any) => m.deviceId)).toContain(vicMac)
    expect(vp.frames[0].macs.every((m: any) => m.ownerUserId === "vic")).toBe(true)
    expect(up.frames[0].macs.map((m: any) => m.deviceId)).toContain(umaMac)
    expect(up.frames[0].macs.every((m: any) => m.ownerUserId === "uma")).toBe(true)
    expect(up.frames[0].macs[0]).not.toHaveProperty("teamId")
    // Uma's Mac comes online, is renamed, goes offline and is deleted: vic's sockets hear none of it.
    const um = await connect(uma, TEAM, umaMac)
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === umaMac && f.mac.online))
    expect((await call("POST", "/v1/devices", uma, { deviceId: umaMac, kind: "mac", name: "Uma Renamed", teamId: TEAM })).status).toBe(200)
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.name === "Uma Renamed"))
    um.ws.close(1000, "done")
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === umaMac && !f.mac.online))
    expect((await call("DELETE", `/v1/devices/${umaMac}`, uma)).status).toBe(200)
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.removed))
    // Vic's own Mac still announces itself to vic: the hub is alive, it just never mixes users.
    vm.ws.close(1000, "done")
    await vp.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === vicMac && !f.mac.online))
    for (const s of [vp, vm]) expect(heard(s)).not.toMatch(new RegExp(`${umaMac}|${umaPhone}|Uma`))
    expect(heard(up)).not.toMatch(new RegExp(`${vicMac}|${vicPhone}|Vic`))
    for (const s of [vp, up]) s.ws.close()
  })

  it("hub: no signal, wg-endpoints or session reuse reaches another user's device, online or not", async () => {
    const { uma, vic, umaPhone, umaMac, vicPhone, vicMac } = await setup()
    const up = await connect(uma, TEAM, umaPhone)
    const um = await connect(uma, TEAM, umaMac)
    const vp = await connect(vic, TEAM, vicPhone)
    const vm = await connect(vic, TEAM, vicMac)
    for (const s of [up, um, vp, vm]) await hello(s)

    // Uma's own session works.
    const sessionId = crypto.randomUUID()
    up.send(offer(umaPhone, umaMac, sessionId, "wg-init"))
    await um.until((s) => s.frames.some((f) => f.type === "signal"))

    // Vic's phone to uma's online Mac: refused as not_owner (never "offline", which would tell it exists).
    for (const kind of ["webrtc-offer", "wg-init", "wg-endpoints", "webrtc-ice", "bye"]) vp.send(offer(vicPhone, umaMac, crypto.randomUUID(), kind))
    // Riding uma's session, in either direction, from vic's phone and vic's Mac.
    vp.send(offer(vicPhone, umaMac, sessionId, "wg-endpoints"))
    vm.send(offer(vicMac, umaPhone, sessionId, "wg-resp"))
    // Vic's Mac starting a session to uma's phone.
    vm.send(offer(vicMac, umaPhone))
    // A spoofed from.
    vp.send(offer(umaPhone, umaMac))
    await vp.until((s) => errors(s).length === 7)
    await vm.until((s) => errors(s).length === 2)
    expect(errors(vp).slice(0, 6).every((e) => e.code === "not_owner")).toBe(true)
    expect(errors(vp)[6]).toMatchObject({ code: "bad_request" })
    expect(errors(vm).every((e) => e.code === "not_owner")).toBe(true)
    // Uma's own Mac (also offline) is equally unknown to vic: same refusal.
    um.ws.close(1000, "done")
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === umaMac && !f.mac.online))
    vp.send(offer(vicPhone, umaMac))
    await vp.until((s) => errors(s).length === 8)
    expect(errors(vp)[7]).toMatchObject({ code: "not_owner" })

    // Retired relay frames addressed to uma's devices are never forwarded either.
    const frame = new Uint8Array(36)
    frame.set(uuidToBytes(sessionId), 0)
    frame.set(uuidToBytes(umaPhone), 16)
    vm.ws.send(frame)
    await vm.until((s) => errors(s).some((e) => e.code === "relay_retired"))

    // Uma's sockets got only uma's own frames.
    expect(up.frames.filter((f) => f.type === "signal")).toHaveLength(0)
    expect(um.frames.filter((f) => f.type === "signal")).toHaveLength(1)
    expect(up.binary.length + um.binary.length).toBe(0)
    for (const s of [up, um]) expect(heard(s)).not.toMatch(new RegExp(`${vicMac}|${vicPhone}|"vic"`))
    for (const s of [up, vp, vm]) s.ws.close()
  })

  it("hub: a user cannot open a socket as a teammate's device", async () => {
    const { vic, umaPhone, umaMac } = await setup()
    for (const id of [umaPhone, umaMac]) {
      const res = await worker.fetch(`https://api.test/v1/teams/${TEAM}/signal?deviceId=${id}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${vic}` } })
      expect(res.status).toBe(403)
    }
  })

  it("a hub refuses a socket that names another owner", async () => {
    const vic = await token("vic")
    await register(vic, "phone", TEAM)
    const umaPhone = await register(await token("uma"), "phone", TEAM)
    // vic's hub, asked (as a routing bug would) to admit uma's device under uma's owner key.
    const claim = { userId: "uma", projectId: "p", deviceId: umaPhone, ownerKey: "uma", teamId: TEAM }
    const res = await hubOf("vic").fetch("https://team-hub/signal", { headers: { upgrade: "websocket", "x-cnx-claim": JSON.stringify(claim) } })
    expect(res.status).toBe(500)
    expect((await hubOf("vic").macs("vic")).every((m) => m.ownerUserId === "vic")).toBe(true)
  })
})

describe("per-user hub: one user's own devices", () => {
  it("a phone dials the user's own Mac in another team; presence still lists one team's Macs", async () => {
    const uma = await token("uma")
    const phone = await register(uma, "phone", TEAM)
    const mac = await register(uma, "mac", "personal-uma", "Uma Air")
    const p = await connect(uma, TEAM, phone)
    const m = await connect(uma, "personal-uma", mac)
    await hello(p)
    await hello(m)
    expect(p.frames[0].macs.map((x: any) => x.deviceId)).not.toContain(mac)
    const sessionId = crypto.randomUUID()
    p.send(offer(phone, mac, sessionId))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "webrtc-answer", sdp: "a" } })
    await p.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(p.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac)).toBe(false)
    for (const s of [p, m]) s.ws.close()
  })

  it("a Mac that moves team is closed with 4001 and drops out of its old team's presence", async () => {
    const uma = await token("uma")
    const phone = await register(uma, "phone", TEAM)
    const other = await register(uma, "phone", "team-u2")
    const mac = await register(uma, "mac", TEAM, "Mover")
    const p = await connect(uma, TEAM, phone)
    const p2 = await connect(uma, "team-u2", other)
    const m = await connect(uma, TEAM, mac)
    let code = 0
    m.ws.addEventListener("close", (e) => {
      code = (e as CloseEvent).code
    })
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    expect((await call("POST", "/v1/devices", uma, { deviceId: mac, kind: "mac", name: "Mover", teamId: "team-u2" })).status).toBe(200)
    await m.until((s) => s.closed)
    expect(code).toBe(4001)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.removed))
    await p2.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && !f.mac.removed))
    // Its old team no longer admits it; its new team does.
    expect((await worker.fetch(`https://api.test/v1/teams/${TEAM}/signal?deviceId=${mac}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${uma}` } })).status).toBe(403)
    const again = await connect(uma, "team-u2", mac)
    await p2.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    for (const s of [p, p2, again]) s.ws.close()
  })

  it("a new hub lists the user's offline Macs from the database (old registrations)", async () => {
    const owner = "wes"
    const mac = crypto.randomUUID()
    // A Mac registered before per-user hubs: in the database only, never announced to this hub.
    const r = await memoryStore().upsertDevice({ deviceId: mac, ownerUserId: owner, teamId: `personal-${owner}`, kind: "mac", name: "Old Mac", wgPublicKey: null })
    expect(r).not.toBe("not_owner")
    const wes = await token(owner)
    const phone = await register(wes, "phone", `personal-${owner}`)
    const p = await connect(wes, `personal-${owner}`, phone)
    await hello(p)
    expect(p.frames[0].macs).toEqual([{ deviceId: mac, name: "Old Mac", online: false, lastSeenAt: null, ownerUserId: owner }])
    // And the phone can dial it once it connects.
    const m = await connect(wes, `personal-${owner}`, mac)
    p.send(offer(phone, mac))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    for (const s of [p, m]) s.ws.close()
  })

  it("account deletion closes every socket with 4002 and empties the hub", async () => {
    const xia = await token("xia")
    const phone = await register(xia, "phone", "personal-xia")
    const mac = await register(xia, "mac", "personal-xia")
    const p = await connect(xia, "personal-xia", phone)
    const codes: Array<number> = []
    p.ws.addEventListener("close", (e) => codes.push((e as CloseEvent).code))
    await hello(p)
    expect((await call("DELETE", "/v1/me", xia)).status).toBe(200)
    await p.until((s) => s.closed)
    expect(codes).toEqual([4002])
    expect(await hubOf("xia").macs("xia")).toEqual([])
    const res = await worker.fetch(`https://api.test/v1/teams/personal-xia/signal?deviceId=${mac}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${xia}` } })
    expect(res.status).toBe(403)
  })
})
