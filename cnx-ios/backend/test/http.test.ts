import { describe, expect, it } from "vitest"
import { call, register, token } from "./helpers.ts"

describe("HTTP API", () => {
  it("health is public", async () => {
    const r = await call("GET", "/v1/health", undefined)
    expect(r).toMatchObject({ status: 200, json: { ok: true, version: "0.3.0" } })
  })

  it("rejects missing, forged, wrong-audience and anonymous tokens", async () => {
    expect((await call("GET", "/v1/ice", undefined)).status).toBe(401)
    expect((await call("GET", "/v1/ice", "not-a-jwt")).status).toBe(401)
    expect((await call("GET", "/v1/ice", await token("alice", { audience: "other-project" }))).status).toBe(401)
    expect((await call("GET", "/v1/ice", await token("alice", { anonymous: true }))).status).toBe(401)
    const r = await call("POST", "/v1/devices", undefined, { deviceId: crypto.randomUUID(), kind: "mac", name: "x", teamId: "team-a" })
    expect(r).toMatchObject({ status: 401, json: { error: { code: "unauthorized" } } })
  })

  it("ice always includes Cloudflare STUN", async () => {
    const r = await call("GET", "/v1/ice", await token("alice"))
    expect(r.status).toBe(200)
    expect(r.json.iceServers[0].urls).toContain("stun:stun.cloudflare.com:3478")
    expect(typeof r.json.ttl).toBe("number")
  })

  it("upserts devices, refuses another owner and non-members", async () => {
    const alice = await token("alice")
    const deviceId = crypto.randomUUID()
    const a = await call("POST", "/v1/devices", alice, { deviceId, kind: "mac", name: "Studio", teamId: "team-a" })
    expect(a).toMatchObject({ status: 200, json: { device: { deviceId, kind: "mac", name: "Studio", teamId: "team-a", ownerUserId: "alice", wgPublicKey: null } } })
    const wg = "A".repeat(43) + "="
    const b = await call("POST", "/v1/devices", alice, { deviceId, kind: "mac", name: "Studio 2", teamId: "team-a", wgPublicKey: wg })
    expect(b.json.device).toMatchObject({ name: "Studio 2", wgPublicKey: wg, createdAt: a.json.device.createdAt })
    const stolen = await call("POST", "/v1/devices", await token("bob"), { deviceId, kind: "mac", name: "Mine now", teamId: "team-a" })
    expect(stolen).toMatchObject({ status: 403, json: { error: { code: "not_owner" } } })
    const outsider = await call("POST", "/v1/devices", await token("mallory"), { deviceId: crypto.randomUUID(), kind: "phone", name: "p", teamId: "team-a" })
    expect(outsider).toMatchObject({ status: 403, json: { error: { code: "not_member" } } })
    const bad = await call("POST", "/v1/devices", alice, { deviceId: "nope", kind: "mac", name: "x", teamId: "team-a" })
    expect(bad.status).toBe(400)
  })

  it("lists team macs with presence fields", async () => {
    const bob = await token("bob")
    const id = await register(bob, "mac", "team-a", "Bob's Mac")
    const r = await call("GET", "/v1/teams/team-a/macs", await token("alice"))
    expect(r.status).toBe(200)
    expect(r.json.macs.find((m: any) => m.deviceId === id)).toEqual({ deviceId: id, name: "Bob's Mac", online: false, lastSeenAt: null, ownerUserId: "bob" })
    expect((await call("GET", "/v1/teams/team-a/macs", await token("mallory"))).status).toBe(403)
  })

  it("stores prefs per user per team", async () => {
    const alice = await token("alice")
    expect((await call("GET", "/v1/teams/team-a/prefs", alice)).json).toEqual({ color: null, emoji: null })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { color: "#ff8800" })).json).toEqual({ color: "#FF8800", emoji: null })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "🚀" })).json).toEqual({ color: "#FF8800", emoji: "🚀" })
    expect((await call("GET", "/v1/teams/team-a/prefs", alice)).json).toEqual({ color: "#FF8800", emoji: "🚀" })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: null })).json).toEqual({ color: "#FF8800", emoji: null })
    expect((await call("GET", "/v1/teams/team-a/prefs", await token("bob"))).json).toEqual({ color: null, emoji: null })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { color: "red" })).status).toBe(400)
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "ab" })).status).toBe(400)
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: " " })).status).toBe(400)
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "" })).json).toEqual({ color: "#FF8800", emoji: "" })
    expect((await call("GET", "/v1/teams/team-a/prefs", alice)).json).toEqual({ color: "#FF8800", emoji: "" })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "Q" })).json).toEqual({ color: "#FF8800", emoji: "Q" })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "👩‍👩‍👧" })).json).toEqual({ color: "#FF8800", emoji: "👩‍👩‍👧" })
    expect((await call("PUT", "/v1/teams/team-a/prefs", await token("mallory"), { color: "#000000" })).status).toBe(403)
  })

  it("invites require membership and an email", async () => {
    expect((await call("POST", "/v1/teams/team-a/invites", await token("alice"), {})).status).toBe(400)
    expect((await call("POST", "/v1/teams/team-a/invites", await token("mallory"), { email: "x@example.com" })).status).toBe(403)
    const r = await call("POST", "/v1/teams/team-a/invites", await token("alice"), { email: "x@example.com" })
    expect(r).toMatchObject({ status: 200, json: { sent: true } })
  })

  it("personal space: owner only, no Stack membership, invites refused", async () => {
    // "solo" is in no Stack team at all.
    const solo = await token("solo")
    const team = "personal-solo"
    const deviceId = crypto.randomUUID()
    expect((await call("POST", "/v1/devices", solo, { deviceId, kind: "mac", name: "Solo Mac", teamId: team })).status).toBe(200)
    const macs = await call("GET", `/v1/teams/${team}/macs`, solo)
    expect(macs.json.macs.map((m: any) => m.deviceId)).toEqual([deviceId])
    expect((await call("PUT", `/v1/teams/${team}/prefs`, solo, { color: "#123456" })).json).toEqual({ color: "#123456", emoji: null })
    const inv = await call("POST", `/v1/teams/${team}/invites`, solo, { email: "x@example.com" })
    expect(inv).toMatchObject({ status: 400, json: { error: { code: "bad_request", message: "personal space has no members" } } })
    const alice = await token("alice")
    expect((await call("GET", `/v1/teams/${team}/macs`, alice)).json).toMatchObject({ error: { code: "not_member" } })
    expect((await call("GET", `/v1/teams/${team}/prefs`, alice)).status).toBe(403)
    expect((await call("POST", "/v1/devices", alice, { deviceId: crypto.randomUUID(), kind: "phone", name: "p", teamId: team })).status).toBe(403)
    expect((await call("POST", `/v1/teams/${team}/invites`, alice, { email: "x@example.com" })).status).toBe(403)
  })
})
