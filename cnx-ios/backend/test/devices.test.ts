import { exportPKCS8, generateKeyPair, decodeProtectedHeader } from "jose"
import { describe, expect, it } from "vitest"
import { apnsPayload, clean, sendApns } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"
import { call, connect, PROD_PROJECT, register, token } from "./helpers.ts"

const HEX = "ab".repeat(32)

describe("device list and removal", () => {
  it("lists the caller's Macs and phones with presence and push state", async () => {
    const t = await token("gina")
    const mac = await register(t, "mac", "personal-gina", "Gina Studio")
    const phone = await register(t, "phone", "personal-gina", "Gina iPhone")
    await register(await token("hank"), "mac", "personal-hank", "Not Gina's")
    const sock = await connect(t, "personal-gina", mac)
    await sock.until((s) => s.frames.some((f) => f.type === "hello"))
    expect((await call("PUT", `/v1/devices/${phone}/push`, t, { token: HEX, environment: "sandbox", topic: "dev.cmux.cnx" })).status).toBe(200)
    const r = await call("GET", "/v1/me/devices", t)
    expect(r.status).toBe(200)
    expect(r.json.devices).toEqual([
      expect.objectContaining({ deviceId: mac, kind: "mac", name: "Gina Studio", teamId: "personal-gina", online: true, push: false }),
      expect.objectContaining({ deviceId: phone, kind: "phone", name: "Gina iPhone", online: null, push: true })
    ])
    sock.ws.close()
  })

  it("deletes only the owner's device, evicts its socket and tells phones it is removed", async () => {
    const t = await token("ivy")
    const mac = await register(t, "mac", "personal-ivy", "Old Mac")
    const phone = await register(t, "phone", "personal-ivy")
    const p = await connect(t, "personal-ivy", phone)
    const m = await connect(t, "personal-ivy", mac)
    let closeCode = 0
    m.ws.addEventListener("close", (e) => {
      closeCode = (e as CloseEvent).code
    })
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.online))
    expect(await call("DELETE", `/v1/devices/${mac}`, await token("jack"))).toMatchObject({ status: 403, json: { error: { code: "not_owner" } } })
    expect(await call("DELETE", `/v1/devices/${mac}`, await token("ivy", { project: PROD_PROJECT }))).toMatchObject({ status: 403 })
    expect(await call("DELETE", `/v1/devices/${mac}`, t)).toEqual({ status: 200, json: { deleted: true, deviceId: mac } })
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.removed === true))
    await m.until((s) => s.closed)
    expect(closeCode).toBe(4002)
    expect((await call("GET", "/v1/me/devices", t)).json.devices.map((d: any) => d.deviceId)).toEqual([phone])
    expect((await call("GET", "/v1/me/macs", t)).json.macs).toEqual([])
    expect(await call("DELETE", `/v1/devices/${mac}`, t)).toMatchObject({ status: 404, json: { error: { code: "not_found" } } })
    // A deleted device must register again before it can open a socket.
    const res = await (await import("./helpers.ts")).worker.fetch(`https://api.test/v1/teams/personal-ivy/signal?deviceId=${mac}`, {
      headers: { Upgrade: "websocket", authorization: `Bearer ${t}` }
    })
    expect(res.status).toBe(403)
    p.ws.close()
  })

  it("account data deletion purges devices, push tokens and prefs", async () => {
    const t = await token("kate")
    await register(t, "mac", "personal-kate")
    const phone = await register(t, "phone", "personal-kate")
    await call("PUT", `/v1/devices/${phone}/push`, t, { token: HEX, environment: "production", topic: "dev.cmux.cnx.prod" })
    await call("PUT", "/v1/teams/personal-kate/prefs", t, { color: "#112233" })
    expect(await call("DELETE", "/v1/me", t)).toEqual({ status: 200, json: { deleted: { devices: 2 } } })
    expect((await call("GET", "/v1/me/devices", t)).json.devices).toEqual([])
    expect((await call("GET", "/v1/teams/personal-kate/prefs", t)).json).toEqual({ color: null, emoji: null })
  })
})

describe("push registration and notify", () => {
  it("validates push registration", async () => {
    const t = await token("liam")
    const phone = await register(t, "phone", "personal-liam")
    const mac = await register(t, "mac", "personal-liam")
    const put = (id: string, body: unknown, tok = t) => call("PUT", `/v1/devices/${id}/push`, tok, body)
    expect((await put(phone, { token: "xyz", environment: "sandbox", topic: "dev.cmux.cnx" })).status).toBe(400)
    expect((await put(phone, { token: HEX, environment: "dev", topic: "dev.cmux.cnx" })).status).toBe(400)
    expect((await put(phone, { token: HEX, environment: "sandbox", topic: "com.evil.app" })).status).toBe(400)
    expect((await put(phone, { token: HEX, environment: "sandbox", topic: "dev.cmux.cnx", kinds: ["nope"] })).status).toBe(400)
    expect((await put(mac, { token: HEX, environment: "sandbox", topic: "dev.cmux.cnx" })).status).toBe(400)
    expect((await put(phone, { token: HEX, environment: "sandbox", topic: "dev.cmux.cnx" }, await token("mona"))).status).toBe(403)
    const ok = await put(phone, { token: HEX.toUpperCase(), environment: "sandbox", topic: "dev.cmux.cnx", kinds: ["question", "permission"] })
    expect(ok).toMatchObject({ status: 200, json: { push: { environment: "sandbox", topic: "dev.cmux.cnx", kinds: ["question", "permission"] } } })
    expect(await call("DELETE", `/v1/devices/${phone}/push`, t)).toEqual({ status: 200, json: { deleted: true } })
    expect((await call("GET", "/v1/me/devices", t)).json.devices.find((d: any) => d.deviceId === phone).push).toBe(false)
  })

  it("notify needs the caller's own Mac and reports an unconfigured APNs key", async () => {
    const t = await token("nora")
    const mac = await register(t, "mac", "personal-nora")
    const phone = await register(t, "phone", "personal-nora")
    const body = { eventId: "evt-1", kind: "question", agent: "Claude", place: "repo" }
    expect((await call("POST", `/v1/devices/${phone}/notify`, t, body)).status).toBe(403)
    expect((await call("POST", `/v1/devices/${mac}/notify`, await token("owen"), body)).status).toBe(403)
    expect((await call("POST", `/v1/devices/${mac}/notify`, t, { ...body, kind: "shell" })).status).toBe(400)
    expect((await call("POST", `/v1/devices/${mac}/notify`, t, { ...body, eventId: "has space" })).status).toBe(400)
    expect(await call("POST", `/v1/devices/${mac}/notify`, t, body)).toEqual({ status: 200, json: { configured: false, sent: 0, failed: 0, dropped: 0 } })
  })

  it("ice reports whether TURN is included", async () => {
    const r = await call("GET", "/v1/ice", await token("alice"))
    expect(r.json.turn).toBe(false)
    expect(r.json.ttl).toBe(3600)
  })
})

describe("APNs payload and sender", () => {
  const event = { eventId: "e1", kind: "permission" as const, agent: "Claude", place: "cmux", macId: "m1", macName: "Studio", sessionId: "s1", tabId: "t1" }

  it("writes fixed text per kind and never agent output", () => {
    const p = apnsPayload(event)
    expect(p.aps.alert).toEqual({ title: "Claude needs permission", body: "cmux · Studio" })
    expect(p.aps["interruption-level"]).toBe("time-sensitive")
    expect(p.cnx).toEqual({ mac: "m1", kind: "permission", eventId: "e1", tabId: "t1", sessionId: "s1" })
    expect(apnsPayload({ ...event, kind: "chief" }).aps.alert.title).toBe("Chief replied")
    expect(apnsPayload({ ...event, kind: "completed", agent: "" }).aps.alert.title).toBe("Your agent finished")
    expect(clean("a\u0000b‮\nc", 40)).toBe("a b c")
    expect(clean("x".repeat(100), 40)).toHaveLength(40)
  })

  it("signs a provider token, routes by environment and classifies answers", async () => {
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const config = { keyP8: await exportPKCS8(privateKey), keyId: "KEY123", teamId: "TEAM123" }
    const target = (token: string, environment: "sandbox" | "production"): PushRegistration => ({
      deviceId: "d",
      ownerUserId: "o",
      token,
      environment,
      topic: "dev.cmux.cnx",
      kinds: ["permission"],
      updatedAt: ""
    })
    const seen: Array<Request> = []
    const fetcher = (async (req: Request) => {
      seen.push(req)
      if (req.url.includes("gone")) return new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 })
      return new Response(null, { status: 200 })
    }) as unknown as typeof fetch
    const r = await sendApns(config, [target("aa", "production"), target("gone", "sandbox")], event, Date.now(), fetcher)
    expect(r.map((x) => x.outcome)).toEqual(["sent", "drop_target"])
    expect(seen[0]!.url).toBe("https://api.push.apple.com/3/device/aa")
    expect(seen[1]!.url).toBe("https://api.sandbox.push.apple.com/3/device/gone")
    expect(seen[0]!.headers.get("apns-topic")).toBe("dev.cmux.cnx")
    expect(seen[0]!.headers.get("apns-collapse-id")).toBe("e1")
    const jwt = seen[0]!.headers.get("authorization")!.slice(7)
    expect(decodeProtectedHeader(jwt)).toMatchObject({ alg: "ES256", kid: "KEY123" })
  })
})
