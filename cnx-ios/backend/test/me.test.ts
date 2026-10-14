import { exportJWK, generateKeyPair, createLocalJWKSet, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { verifyWithKeys, type KeySet } from "../src/auth.ts"
import { call, connect, DEV_PROJECT, PROD_PROJECT, register, token, worker } from "./helpers.ts"

describe("GET /v1/me/macs", () => {
  it("lists the caller's own Macs in every team and the personal space, with presence", async () => {
    const carol = await token("carol")
    const inTeam = await register(carol, "mac", "team-c", "Carol Studio")
    const inPersonal = await register(carol, "mac", "personal-carol", "Carol Air")
    await register(carol, "phone", "team-c", "Carol iPhone")
    // A teammate's Mac in the same team is not the caller's: not listed.
    await register(await token("dave"), "mac", "team-c", "Dave Mac")
    const mac = await connect(carol, "team-c", inTeam)
    await mac.until((s) => s.frames.some((f) => f.type === "hello"))
    const r = await call("GET", "/v1/me/macs", carol)
    expect(r.status).toBe(200)
    expect(r.json.macs).toEqual([
      { deviceId: inPersonal, name: "Carol Air", teamId: "personal-carol", online: false, lastSeenAt: null, ownerUserId: "carol" },
      { deviceId: inTeam, name: "Carol Studio", teamId: "team-c", online: true, lastSeenAt: expect.any(String), ownerUserId: "carol" }
    ])
    mac.ws.close()
  })

  it("follows a Mac that moved to another space", async () => {
    const carol = await token("carol")
    const deviceId = await register(carol, "mac", "personal-carol", "Mover")
    expect((await call("POST", "/v1/devices", carol, { deviceId, kind: "mac", name: "Mover", teamId: "team-c" })).status).toBe(200)
    const listed = (await call("GET", "/v1/me/macs", carol)).json.macs.filter((m: any) => m.deviceId === deviceId)
    expect(listed.map((m: any) => m.teamId)).toEqual(["team-c"])
  })

  it("is per user and per project", async () => {
    const erin = await token("erin")
    const gone = crypto.randomUUID()
    expect((await call("POST", "/v1/devices", erin, { deviceId: gone, kind: "mac", name: "Erin Mac", teamId: "team-e" })).status).toBe(200)
    expect((await call("GET", "/v1/me/macs", erin)).json.macs.map((m: any) => m.deviceId)).toEqual([gone])
    expect((await call("GET", "/v1/me/macs", await token("frank"))).json).toEqual({ macs: [] })
    // The same sub in the production project is another user.
    expect((await call("GET", "/v1/me/macs", await token("carol", { project: PROD_PROJECT }))).json).toEqual({ macs: [] })
    expect((await call("GET", "/v1/me/macs", undefined)).status).toBe(401)
    expect(DEV_PROJECT).not.toBe(PROD_PROJECT)
  })

  it("says why a token was refused", async () => {
    const r = await call("GET", "/v1/me/macs", await token("carol", { anonymous: true }))
    expect(r).toMatchObject({ status: 401, json: { error: { code: "unauthorized", message: "missing or invalid Stack access token (anonymous)" } } })
    const restricted = await call("GET", "/v1/me/macs", await token("carol", { restricted: true }))
    expect(restricted.json.error.message).toContain("(restricted)")
  })
})

describe("signing keys", () => {
  const project = "proj-1"
  const sign = async (kid: string, key: CryptoKey) =>
    new SignJWT({}).setProtectedHeader({ alg: "ES256", kid }).setIssuer(`https://api.stack-auth.com/api/v1/projects/${project}`).setAudience(project).setSubject("u").setIssuedAt().setExpirationTime("5m").sign(key)
  const pair = async (kid: string) => {
    const k = await generateKeyPair("ES256", { extractable: true })
    return { kid, privateKey: k.privateKey, jwk: { ...(await exportJWK(k.publicKey)), kid, alg: "ES256" } as JWK }
  }

  it("refetches the keys at once for a kid the cached set lacks", async () => {
    const old = await pair("old")
    const rotated = await pair("new")
    let published: Array<JWK> = [old.jwk]
    let local = createLocalJWKSet({ keys: published })
    let reloads = 0
    const keys: KeySet = {
      get: (h, t) => local(h, t),
      reload: async () => {
        reloads++
        local = createLocalJWKSet({ keys: published })
      }
    }
    expect((await verifyWithKeys(await sign("old", old.privateKey), keys, project)).ok).toBe(true)
    // Stack publishes a new key; the cached set does not have it yet.
    published = [old.jwk, rotated.jwk]
    expect((await verifyWithKeys(await sign("new", rotated.privateKey), keys, project)).ok).toBe(true)
    expect(reloads).toBe(1)
  })

  it("retries once when the key fetch fails, and reports a key that stays unknown", async () => {
    const k = await pair("k")
    let fail = true
    const keys: KeySet = {
      get: async (h, t) => {
        if (fail) throw new TypeError("network connection lost")
        return createLocalJWKSet({ keys: [k.jwk] })(h, t)
      },
      reload: async () => {
        fail = false
      }
    }
    expect((await verifyWithKeys(await sign("k", k.privateKey), keys, project)).ok).toBe(true)
    const stranger = await pair("stranger")
    expect(await verifyWithKeys(await sign("stranger", stranger.privateKey), keys, project)).toEqual({ ok: false, rejection: "unknown_key" })
  })
})

describe("POST /v1/me/bootstrap", () => {
  it("registers the phone's devices and returns the team's Macs, the caller's Macs and ICE in one call", async () => {
    const gina = await token("gina")
    const mac = await register(gina, "mac", "personal-gina", "Gina Mac")
    const link = crypto.randomUUID()
    const presence = crypto.randomUUID()
    const r = await call("POST", "/v1/me/bootstrap", gina, {
      teamId: "personal-gina",
      devices: [
        { deviceId: link, kind: "phone", name: "Gina iPhone" },
        { deviceId: presence, kind: "phone", name: "Gina iPhone (presence)" }
      ]
    })
    expect(r.status).toBe(200)
    expect(r.json.devices.map((d: any) => d.device.deviceId)).toEqual([link, presence])
    expect(r.json.macs.macs.map((m: any) => m.deviceId)).toEqual([mac])
    expect(r.json.myMacs.macs.map((m: any) => m.deviceId)).toEqual([mac])
    expect(r.json.ice.iceServers.length).toBeGreaterThan(0)
    // The registered link device opens its signal socket straight away.
    const sock = await connect(gina, "personal-gina", link)
    await sock.until((s) => s.frames.some((f) => f.type === "hello"))
    sock.ws.close()
  })

  it("carries a part's error without failing the rest", async () => {
    const gina = await token("gina")
    const r = await call("POST", "/v1/me/bootstrap", gina, { teamId: "personal-someone-else", devices: [] })
    expect(r.status).toBe(200)
    expect(r.json.macs.error.code).toBe("not_member")
    expect(Array.isArray(r.json.myMacs.macs)).toBe(true)
  })
})

describe("Server-Timing", () => {
  it("names the steps a request waited on", async () => {
    const res = await worker.fetch("https://api.test/v1/me/macs", { headers: { authorization: `Bearer ${await token("hana")}` } })
    const header = res.headers.get("server-timing") ?? ""
    expect(header).toContain("auth;dur=")
    expect(header).toContain("total;dur=")
  })
})
