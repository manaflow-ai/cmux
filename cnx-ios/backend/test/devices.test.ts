import { describe, expect, it } from "vitest"
import { call, connect, register, token } from "./helpers.ts"

describe("device list and removal", () => {
  it("lists the caller's own Macs and phones only", async () => {
    const alice = await token("alice")
    const mac = await register(alice, "mac", "team-a", "Alice's Mac")
    const phone = await register(alice, "phone", "team-a", "Alice's iPhone")
    const bobs = await register(await token("bob"), "phone", "team-a", "Bob's iPhone")
    const r = await call("GET", "/v1/me/devices", alice)
    expect(r.status).toBe(200)
    const ids = r.json.devices.map((d: any) => d.deviceId)
    expect(ids).toContain(mac)
    expect(ids).toContain(phone)
    expect(ids).not.toContain(bobs)
    expect(r.json.devices.find((d: any) => d.deviceId === phone)).toMatchObject({ kind: "phone", name: "Alice's iPhone", teamId: "team-a" })
    expect((await call("GET", "/v1/me/devices", undefined)).status).toBe(401)
  })

  it("only the owner removes a device; another user's or a missing one is 404", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    expect((await call("DELETE", `/v1/devices/${phone}`, await token("bob"))).status).toBe(404)
    expect((await call("DELETE", "/v1/devices/not-a-uuid", alice)).status).toBe(400)
    expect(await call("DELETE", `/v1/devices/${phone}`, alice)).toMatchObject({ status: 200, json: { removed: true, deviceId: phone } })
    expect((await call("DELETE", `/v1/devices/${phone}`, alice)).status).toBe(404)
    const listed = (await call("GET", "/v1/me/devices", alice)).json.devices.map((d: any) => d.deviceId)
    expect(listed).not.toContain(phone)
  })

  it("removing a Mac closes its socket with 4002, reports it offline and drops it from the team", async () => {
    const alice = await token("alice")
    const mac = await register(alice, "mac", "team-a", "Removed Mac")
    const phone = await register(alice, "phone", "team-a")
    const m = await connect(alice, "team-a", mac)
    const p = await connect(alice, "team-a", phone)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    let code = 0
    m.ws.addEventListener("close", (e) => {
      code = (e as CloseEvent).code
    })
    expect((await call("DELETE", `/v1/devices/${mac}`, alice)).status).toBe(200)
    await m.until((s) => s.closed)
    expect(code).toBe(4002)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac?.deviceId === mac && f.mac.online === false))
    const macs = (await call("GET", "/v1/teams/team-a/macs", alice)).json.macs.map((x: any) => x.deviceId)
    expect(macs).not.toContain(mac)
    // A removed device can no longer open the signaling socket until it registers again.
    const res = await (await import("./helpers.ts")).worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${mac}`, {
      headers: { Upgrade: "websocket", authorization: `Bearer ${alice}` }
    })
    expect(res.status).toBe(403)
    p.ws.close()
  })
})
