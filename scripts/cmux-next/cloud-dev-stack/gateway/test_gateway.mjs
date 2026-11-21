// Tests for the public gateway (no Cloudflare): node --test scripts/cmux-next/cloud-dev-stack/gateway/test_gateway.mjs
// Real ES256 tokens, signed here; a fake VM binding records what reaches the stack.
import assert from "node:assert/strict"
import { test } from "node:test"
import { clearKeyCache, handle } from "./index.js"

const STACK_ISSUER = "https://api.stack-auth.com/api/v1/projects/454ecd03-1db2-4050-845e-4ce5b0cd9895"
const b64 = (bytes) => Buffer.from(bytes).toString("base64url")

async function keypair(kid) {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  return { pair, jwk: { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, kid } }
}

async function sign(key, claims, kid, typ = "JWT") {
  const head = b64(JSON.stringify({ alg: "ES256", typ, kid }))
  const body = b64(JSON.stringify(claims))
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${head}.${body}`))
  return `${head}.${body}.${b64(new Uint8Array(sig))}`
}

const NOW = 1_800_000_000_000
const teamClaims = (over = {}) => ({
  iss: STACK_ISSUER, aud: "454ecd03-1db2-4050-845e-4ce5b0cd9895", sub: "u1", email: "agent@manaflow.ai", email_verified: true,
  is_anonymous: false, is_restricted: false, exp: NOW / 1000 + 600, ...over,
})

async function setup() {
  clearKeyCache()
  const stack = await keypair("stack-1")
  const own = await keypair("hub-session")
  const seen = []
  const env = {
    WDEV_ALLOWED_EMAIL_DOMAINS: "manaflow.ai",
    VM: {
      fetch: async (req) => {
        seen.push({ url: req.url, method: req.method, body: req.method === "POST" ? await req.text() : "", auth: req.headers.get("authorization") })
        return new Response("from the stack", { status: 200 })
      },
    },
  }
  const deps = { now: NOW, stackKeys: async () => [stack.jwk], ownKeys: async () => [own.jwk] }
  const call = (url, init = {}) => handle(new Request(url, init), env, deps)
  return { stack, own, seen, call }
}

test("a verified cmux-team Stack token is admitted on every service and reaches the slot's host", async () => {
  const { stack, seen, call } = await setup()
  const token = await sign(stack, teamClaims(), "stack-1")
  for (const svc of ["api", "mobile", "hub"]) {
    const r = await call(`https://${svc}.s7.wdev.cmux.dev/v1/me/macs?x=1`, { headers: { authorization: `Bearer ${token}` } })
    assert.equal(r.status, 200, svc)
  }
  assert.deepEqual(seen.map((s) => s.url), [
    "http://api.s7.wdev.cmux.dev/v1/me/macs?x=1",
    "http://mobile.s7.wdev.cmux.dev/v1/me/macs?x=1",
    "http://hub.s7.wdev.cmux.dev/v1/me/macs?x=1",
  ])
  assert.equal(seen[0].auth, `Bearer ${token}`, "the stack verifies the same credential again")
})

test("no credential, a forged, expired, foreign or outside-the-team token never reaches the stack", async () => {
  const { stack, seen, call } = await setup()
  const forger = await keypair("stack-1")
  const cases = {
    none: undefined,
    garbage: "Bearer not-a-jwt",
    forged: `Bearer ${await sign(forger, teamClaims(), "stack-1")}`,
    expired: `Bearer ${await sign(stack, teamClaims({ exp: NOW / 1000 - 1 }), "stack-1")}`,
    "other project": `Bearer ${await sign(stack, teamClaims({ aud: "9790718f-14cd-4f7e-824d-eaf527a82b82" }), "stack-1")}`,
    "outside the team": `Bearer ${await sign(stack, teamClaims({ email: "someone@gmail.com" }), "stack-1")}`,
    unverified: `Bearer ${await sign(stack, teamClaims({ email_verified: false }), "stack-1")}`,
    anonymous: `Bearer ${await sign(stack, teamClaims({ is_anonymous: true }), "stack-1")}`,
    "look-alike domain": `Bearer ${await sign(stack, teamClaims({ email: "x@evilmanaflow.ai" }), "stack-1")}`,
  }
  for (const [name, auth] of Object.entries(cases)) {
    const r = await call("https://api.s7.wdev.cmux.dev/v1/ops", { method: "POST", body: "{}", headers: auth ? { authorization: auth } : {} })
    assert.equal(r.status, 401, name)
  }
  assert.equal(seen.length, 0)
})

test("a token the stack itself issued (hub session, ticket, API install token) is admitted by its own keys", async () => {
  const { own, seen, call } = await setup()
  const session = await sign(own, { iss: "device-hub", sub: "p:u1", exp: NOW / 1000 + 3600 }, "hub-session")
  assert.equal((await call("https://hub.s7.wdev.cmux.dev/v1/devices", { headers: { authorization: `Bearer ${session}` } })).status, 200)
  const ticket = await sign(own, { sub: "p:u1", scope: "full", exp: NOW / 1000 + 60, jti: "t1" }, "hub-session", "dh-ticket")
  const ws = await call(`https://hub.s7.wdev.cmux.dev/v1/sessions/0b8e7c1e-1111-4111-8111-111111111111/ws?ticket=${ticket}`)
  assert.equal(ws.status, 200)
  const stranger = await keypair("hub-session")
  const foreign = await sign(stranger, { iss: "device-hub", sub: "p:u1", exp: NOW / 1000 + 3600 }, "hub-session")
  assert.equal((await call("https://hub.s7.wdev.cmux.dev/v1/devices", { headers: { authorization: `Bearer ${foreign}` } })).status, 401)
  assert.equal(seen.length, 2)
})

test("the mobile Worker's WebSocket bearer subprotocol and the hub's sign-in body are read and re-sent", async () => {
  const { stack, seen, call } = await setup()
  const token = await sign(stack, teamClaims(), "stack-1")
  const ws = await call("https://mobile.s7.wdev.cmux.dev/v1/teams/t/ws", { headers: { "sec-websocket-protocol": `cmux.v1, bearer.${token}` } })
  assert.equal(ws.status, 200)
  const body = JSON.stringify({ token })
  const signIn = await call("https://hub.s7.wdev.cmux.dev/v1/auth/stack", { method: "POST", body, headers: { "content-type": "application/json" } })
  assert.equal(signIn.status, 200)
  assert.equal(seen[1].body, body, "the body the gateway read reaches the hub intact")
  const bad = await call("https://hub.s7.wdev.cmux.dev/v1/auth/stack", { method: "POST", body: JSON.stringify({ token: "x.y.z" }) })
  assert.equal(bad.status, 401)
})

test("only health, the API's client-config and its JWKS are open; other hosts are not the gateway's", async () => {
  const { seen, call } = await setup()
  for (const url of ["https://api.s7.wdev.cmux.dev/v1/health", "https://mobile.s7.wdev.cmux.dev/v1/health", "https://hub.s7.wdev.cmux.dev/v1/health",
                     "https://api.s7.wdev.cmux.dev/v1/client-config", "https://api.s7.wdev.cmux.dev/.well-known/jwks.json"]) {
    assert.equal((await call(url)).status, 200, url)
  }
  assert.equal((await call("https://mobile.s7.wdev.cmux.dev/v1/client-config")).status, 401)
  assert.equal((await call("https://api.s7.wdev.cmux.dev/v1/health", { method: "POST" })).status, 401)
  for (const url of ["https://other.s7.wdev.cmux.dev/v1/health", "https://api.s7.wdev.cmux.dev.evil.example/v1/health",
                     "https://api.s7777.wdev.cmux.dev/v1/health", "https://api.s7.wdev.cmux.dev:8443/v1/health"]) {
    assert.equal((await call(url)).status, 404, url)
  }
  assert.equal(seen.length, 5)
})

test("a token the stack signed for anything but a signed-in account never admits a request", async () => {
  const { own, seen, call } = await setup()
  const api = await sign(own, { iss: "https://api.s7.wdev.cmux.dev", aud: "api", sub: "u1", exp: NOW / 1000 + 600 }, "hub-session")
  assert.equal((await call("https://api.s7.wdev.cmux.dev/v1/me", { headers: { authorization: `Bearer ${api}` } })).status, 200)
  for (const [claims, typ] of [
    [{ iss: "https://api.s7.wdev.cmux.dev", aud: "cmux-integration-state", sub: "u1", exp: NOW / 1000 + 600 }, "JWT"], // OAuth state
    [{ iss: "https://api.s7.wdev.cmux.dev", aud: "cmux-model-gateway", sub: "run", exp: NOW / 1000 + 600 }, "JWT"], // run token
    [{ iss: "https://api.s7.wdev.cmux.dev", aud: "cmux-free", sub: "k", fr: 1, exp: NOW / 1000 + 600 }, "cmux-free+jwt"],
    [{ iss: "https://api.s7.wdev.cmux.dev", aud: ["api", "other"], sub: "u1", exp: NOW / 1000 + 600 }, "JWT"],
    [{ iss: "device-hub", exp: NOW / 1000 + 600 }, "JWT"], // a hub session with no subject
  ]) {
    const token = await sign(own, claims, "hub-session", typ)
    const r = await call("https://api.s7.wdev.cmux.dev/v1/me", { headers: { authorization: `Bearer ${token}` } })
    assert.equal(r.status, 401, JSON.stringify(claims))
    assert.match((await r.json()).error.message, /not a kind of token/)
  }
  assert.equal(seen.length, 1)
})

test("a flood of tokens under unknown keys fetches the key sets at most once a minute", async () => {
  clearKeyCache()
  const stack = await keypair("stack-1")
  const own = await keypair("hub-session")
  let stackFetches = 0
  let ownFetches = 0
  const env = { WDEV_ALLOWED_EMAIL_DOMAINS: "manaflow.ai", VM: { fetch: async () => new Response("ok") } }
  const at = (now) => ({ now, stackKeys: async () => (stackFetches++, [stack.jwk]), ownKeys: async () => (ownFetches++, [own.jwk]) })
  const stranger = await keypair("stack-2")
  for (let i = 0; i < 20; i++) {
    const forged = await sign(stranger, teamClaims({ exp: NOW / 1000 + 600 }), `stack-x${i}`)
    const r = await handle(new Request("https://api.s7.wdev.cmux.dev/v1/me", { headers: { authorization: `Bearer ${forged}` } }), env, at(NOW + i))
    assert.equal(r.status, 401)
    const hub = await sign(stranger, { iss: "device-hub", sub: "p:u1", exp: NOW / 1000 + 600 }, `own-x${i}`)
    assert.equal((await handle(new Request("https://hub.s7.wdev.cmux.dev/v1/devices", { headers: { authorization: `Bearer ${hub}` } }), env, at(NOW + i))).status, 401)
  }
  assert.ok(stackFetches <= 2, `${stackFetches} Stack key fetches`)
  assert.ok(ownFetches <= 2, `${ownFetches} stack key fetches`)
  // A minute later a new key is picked up again.
  const good = await sign(stack, teamClaims({ exp: NOW / 1000 + 600 }), "stack-1")
  assert.equal((await handle(new Request("https://api.s7.wdev.cmux.dev/v1/me", { headers: { authorization: `Bearer ${good}` } }), env, at(NOW + 61_000))).status, 200)
})
