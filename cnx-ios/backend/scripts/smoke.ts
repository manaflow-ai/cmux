#!/usr/bin/env bun
/**
 * Live smoke test of a deployed cnx-ios-api (PROTOCOL.md v1). Never prints tokens.
 *
 *   CNX_TOKEN_FILE=/path/to/token bun scripts/smoke.ts            # a Stack access token in a 0600 file
 *   STACK_EMAIL=... STACK_PASSWORD=... bun scripts/smoke.ts       # password sign-in on the dev project
 *
 * Env: CNX_BASE_URL (default the dev Worker), STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY (dev defaults).
 */
import { readFileSync } from "node:fs"

const BASE = process.env.CNX_BASE_URL ?? "https://cnx-ios-api-dev.debussy.workers.dev"
const PROJECT = process.env.STACK_PROJECT_ID ?? "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const PCK = process.env.STACK_PUBLISHABLE_CLIENT_KEY ?? "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
const stackHeaders = (extra: Record<string, string> = {}) => ({ "content-type": "application/json", "x-stack-project-id": PROJECT, "x-stack-access-type": "client", ...(PCK ? { "x-stack-publishable-client-key": PCK } : {}), ...extra })

let failures = 0
const check = (name: string, ok: boolean, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`)
  if (!ok) failures++
}

const token = await (async () => {
  if (process.env.CNX_TOKEN_FILE) return readFileSync(process.env.CNX_TOKEN_FILE, "utf8").trim()
  if (process.env.STACK_EMAIL && process.env.STACK_PASSWORD) {
    const r = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", { method: "POST", headers: stackHeaders(), body: JSON.stringify({ email: process.env.STACK_EMAIL, password: process.env.STACK_PASSWORD }) })
    if (!r.ok) throw new Error(`Stack sign-in returned ${r.status}`)
    return ((await r.json()) as { access_token: string }).access_token
  }
  throw new Error("set CNX_TOKEN_FILE or STACK_EMAIL/STACK_PASSWORD")
})()

const api = async (method: string, path: string, body?: unknown, auth = true) => {
  const r = await fetch(`${BASE}${path}`, { method, headers: { "content-type": "application/json", ...(auth ? { authorization: `Bearer ${token}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: r.status, json: (await r.json().catch(() => null)) as any }
}

// 1. health and auth
const health = await api("GET", "/v1/health", undefined, false)
check("health", health.status === 200 && health.json?.ok === true, `version ${health.json?.version}`)
check("rejects missing token", (await api("GET", "/v1/ice", undefined, false)).status === 401)

// 2. the caller's first Stack team
const teamsRes = await fetch("https://api.stack-auth.com/api/v1/teams?user_id=me", { headers: stackHeaders({ "x-stack-access-token": token }) })
const teamId = (((await teamsRes.json()) as { items?: Array<{ id: string }> }).items ?? [])[0]?.id
check("stack team", !!teamId)
if (!teamId) process.exit(1)

// 3. ICE
const ice = await api("GET", "/v1/ice")
const urls: Array<string> = (ice.json?.iceServers ?? []).flatMap((s: any) => s.urls)
check("ice stun", ice.status === 200 && urls.includes("stun:stun.cloudflare.com:3478"))
check("ice turn", urls.some((u) => u.startsWith("turn")), `${urls.filter((u) => u.startsWith("turn")).length} turn urls, ttl ${ice.json?.ttl}`)

// 4. devices, macs, prefs
const macId = crypto.randomUUID()
const phoneId = crypto.randomUUID()
const mac = await api("POST", "/v1/devices", { deviceId: macId, kind: "mac", name: "smoke-mac", teamId })
const phone = await api("POST", "/v1/devices", { deviceId: phoneId, kind: "phone", name: "smoke-phone", teamId })
check("device upsert", mac.status === 200 && phone.status === 200 && mac.json.device.deviceId === macId, `${mac.status}/${phone.status}`)
const rename = await api("POST", "/v1/devices", { deviceId: macId, kind: "mac", name: "smoke-mac-renamed", teamId })
check("device rename", rename.json?.device?.name === "smoke-mac-renamed" && rename.json.device.createdAt === mac.json.device.createdAt)
const macs = await api("GET", `/v1/teams/${teamId}/macs`)
check("team macs", macs.status === 200 && macs.json.macs.some((m: any) => m.deviceId === macId && m.online === false))
const color = `#${Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, "0").toUpperCase()}`
const put = await api("PUT", `/v1/teams/${teamId}/prefs`, { color, emoji: "🧪" })
const got = await api("GET", `/v1/teams/${teamId}/prefs`)
check("prefs", put.status === 200 && got.json?.color === color && got.json?.emoji === "🧪")
check("foreign team refused", (await api("GET", `/v1/teams/00000000-0000-0000-0000-000000000000/macs`)).status === 403)

// 5. two-client signaling
const wsUrl = `${BASE.replace(/^http/, "ws")}/v1/teams/${teamId}/signal`
const open = (deviceId: string) =>
  new Promise<{ ws: WebSocket; frames: Array<any>; bins: Array<Uint8Array>; wait: (p: (f: any) => boolean, ms?: number) => Promise<any> }>((resolve, reject) => {
    const ws = new WebSocket(`${wsUrl}?deviceId=${deviceId}`, ["cnx.v1", `bearer.${token}`])
    ws.binaryType = "arraybuffer"
    const frames: Array<any> = []
    const bins: Array<Uint8Array> = []
    const waiters: Array<() => void> = []
    ws.addEventListener("message", (e: MessageEvent) => {
      if (typeof e.data === "string") frames.push(JSON.parse(e.data))
      else bins.push(new Uint8Array(e.data as ArrayBuffer))
      waiters.splice(0).forEach((w) => w())
    })
    const wait = async (p: (f: any) => boolean, ms = 5000) => {
      const end = Date.now() + ms
      for (;;) {
        const hit = frames.find(p)
        if (hit) return hit
        if (Date.now() > end) return undefined
        await new Promise<void>((r) => {
          waiters.push(r)
          setTimeout(r, 100)
        })
      }
    }
    ws.addEventListener("open", () => resolve({ ws, frames, bins, wait }))
    ws.addEventListener("error", () => reject(new Error(`websocket ${deviceId.slice(0, 8)} failed`)))
  })

const m = await open(macId)
check("mac hello", !!(await m.wait((f) => f.type === "hello")))
const p = await open(phoneId)
const hello = await p.wait((f) => f.type === "hello")
check("phone hello lists mac online", !!hello?.macs?.some((x: any) => x.deviceId === macId && x.online), `subprotocol ${p.ws.protocol}`)

const sessionId = crypto.randomUUID()
p.ws.send(JSON.stringify({ type: "signal", to: macId, from: phoneId, sessionId, payload: { kind: "webrtc-offer", sdp: "v=0 smoke" } }))
const offer = await m.wait((f) => f.type === "signal" && f.sessionId === sessionId)
check("offer phone->mac", offer?.from === phoneId && offer?.payload?.sdp === "v=0 smoke")
check("offer carries fromUserId", typeof offer?.fromUserId === "string" && offer.fromUserId.length > 0)
m.ws.send(JSON.stringify({ type: "signal", to: phoneId, from: macId, sessionId, payload: { kind: "webrtc-answer", sdp: "v=0 answer" } }))
const answer = await p.wait((f) => f.type === "signal" && f.sessionId === sessionId)
check("answer mac->phone", answer?.from === macId && answer?.payload?.kind === "webrtc-answer")

const hex = (id: string) => Uint8Array.from(id.replace(/-/g, "").match(/../g)!.map((h) => parseInt(h, 16)))
const frame = new Uint8Array(36)
frame.set(hex(sessionId), 0)
frame.set(hex(macId), 16)
frame.set([9, 8, 7, 6], 32)
p.ws.send(frame)
const deadline = Date.now() + 5000
while (!m.bins.length && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50))
const relayed = m.bins[0]
check("relay rewrite", !!relayed && relayed.subarray(16, 32).every((b, i) => b === hex(phoneId)[i]) && relayed[32] === 9)

p.ws.send(JSON.stringify({ type: "signal", to: phoneId, from: phoneId, sessionId: crypto.randomUUID(), payload: { kind: "bye", reason: "x" } }))
check("self-signal refused", (await p.wait((f) => f.type === "error" && f.code === "not_owner"))?.code === "not_owner")

m.ws.close(1000, "smoke done")
const off = await p.wait((f) => f.type === "presence" && f.mac?.deviceId === macId && f.mac.online === false)
check("presence offline", !!off, off?.mac?.lastSeenAt ? "lastSeenAt set" : "")
p.ws.close(1000, "smoke done")

console.log(failures ? `${failures} check(s) failed` : "all checks passed")
process.exit(failures ? 1 : 0)
