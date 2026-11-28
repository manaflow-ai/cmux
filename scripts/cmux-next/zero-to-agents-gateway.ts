#!/usr/bin/env bun
/**
 * Step 3's other end in .github/workflows/machine-zero-to-agents-e2e.yml: the team's inference gateway for its
 * hub-joined machines, run on the CI runner (the person's own computer in this test), never on the joined machine.
 *
 *   bun scripts/cmux-next/zero-to-agents-gateway.ts --cmux PATH --stub PATH --dir DIR
 *
 * Signs in as the development stack account (CMUX_UITEST_STACK_EMAIL and _PASSWORD, env only), registers a
 * throwaway cmux install and keeps its access token in DIR/token (0600, refreshed before it expires; the gateway
 * reads it again on every connect). Starts the shared model stub (tests/fixtures/model-stub/model_stub.py) on
 * loopback, the person's own proxy here, and `cmux inference gateway --upstream` in front of it, the way
 * gateway-e2e.yml's mac job runs it (`--gateway-local`). Puts the team in mode `joined` (InferenceGateway.ts: only
 * its hub-joined machines' `cmm_` calls are routed to the gateway; its Cloud machines get no edge rule, as in `off`).
 * Once the gateway is online it writes DIR/ready.json: {team, mode_before, nonce} (no secret).
 *
 * On SIGTERM (or its own 80-minute deadline) it puts the team's mode back as it found it, stops the gateway and the
 * stub, revokes the install and signs out, then writes DIR/done.json: {restored, revoked}. Nothing here prints a
 * token; the gateway's and the stub's logs (DIR/gateway.log, DIR/stub.log) name machines, paths and statuses only.
 */
import { spawn, type ChildProcess } from "node:child_process"
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import path from "node:path"
import { DEV_API } from "./machine-join-e2e.ts"

const STACK_API = "https://api.stack-auth.com/api/v1"
// The development Stack project's public client pair, as machine-join-e2e.ts uses it.
const STACK_HEADERS = {
  "x-stack-project-id": "454ecd03-1db2-4050-845e-4ce5b0cd9895",
  "x-stack-publishable-client-key": "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
  "x-stack-access-type": "client",
}
const USER_AGENT = "cmux-zero-to-agents-gateway/1"
const ONLINE_LIMIT_MS = 90_000
const DEADLINE_MS = 80 * 60_000

const arg = (name: string) => {
  const i = process.argv.indexOf(name)
  const v = i >= 0 ? process.argv[i + 1] : undefined
  if (!v || !v.startsWith("/")) throw new Error(`${name} takes an absolute path`)
  return v
}
const cmux = arg("--cmux")
const stubPy = arg("--stub")
const dir = arg("--dir")
mkdirSync(dir, { recursive: true, mode: 0o700 })
const say = (line: string) => console.log(`zero-to-agents-gateway: ${line}`)
const writeJson = (name: string, value: unknown) => {
  const tmp = path.join(dir, `.${name}.tmp`)
  writeFileSync(tmp, `${JSON.stringify(value)}\n`, { mode: 0o644 })
  renameSync(tmp, path.join(dir, name))
}
const plainCode = (j: any) =>
  [j?.code, j?.error?.code].find((c) => typeof c === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(c)) ?? ""

const call = async (url: string, init: { method: string; headers?: Record<string, string>; body?: unknown }) => {
  const res = await fetch(url, {
    method: init.method,
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
    headers: { "user-agent": USER_AGENT, ...(init.body === undefined ? {} : { "content-type": "application/json" }), ...init.headers },
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  })
  return { status: res.status, json: (await res.json().catch(() => ({}))) as any }
}
const refused = (step: string, r: { status: number; json: any }) => new Error(`${step}: HTTP ${r.status} ${plainCode(r.json)}`.trim())

let stack: { access: string; refresh: string } | undefined
let user = ""
let install = ""
let keys: CryptoKeyPair | undefined
let access: { token: string; expiresAt: number } | undefined
let modeBefore: { mode: string; machine: string | null } | undefined
let stub: ChildProcess | undefined
let gateway: ChildProcess | undefined
let stopping = false

const op = async (name: string, params: unknown) => {
  const r = await call(`${DEV_API}/v1/ops`, {
    method: "POST",
    headers: { authorization: `Bearer ${stack!.access}` },
    body: { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" },
  })
  if (r.status !== 200 || r.json?.ok !== true) throw refused(name, r)
  return r.json.value
}
/** A fresh install access token, written to DIR/token for the gateway. */
const mint = async () => {
  const ch = await call(`${DEV_API}/v1/auth/challenge`, { method: "POST", body: { user, install } })
  if (ch.status !== 200 || typeof ch.json?.nonce !== "string") throw refused("auth challenge", ch)
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys!.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const tok = await call(`${DEV_API}/v1/auth/token`, {
    method: "POST",
    body: { user, install, nonce: ch.json.nonce, signature: Buffer.from(sig).toString("base64url") },
  })
  if (tok.status !== 200 || typeof tok.json?.access_token !== "string") throw refused("auth token", tok)
  const expires = Number(tok.json.expires_at)
  access = { token: tok.json.access_token, expiresAt: Number.isFinite(expires) && expires > 0 ? (expires < 1e12 ? expires * 1000 : expires) : Date.now() + 300_000 }
  const file = path.join(dir, "token")
  writeFileSync(`${file}.tmp`, access.token, { mode: 0o600 })
  renameSync(`${file}.tmp`, file)
  return { team: typeof tok.json.team === "string" ? tok.json.team : "", ttl: Math.round((access.expiresAt - Date.now()) / 1000) }
}
const api = (method: string, p: string, body?: unknown) =>
  call(`${DEV_API}${p}`, { method, headers: { authorization: `Bearer ${access!.token}` }, ...(body === undefined ? {} : { body }) })

const stopChild = async (child: ChildProcess | undefined) => {
  if (!child || child.exitCode !== null || child.signalCode !== null) return
  child.kill("SIGTERM")
  const ended = new Promise((r) => child.once("exit", r))
  await Promise.race([ended, Bun.sleep(15_000)])
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL")
}

const cleanup = async () => {
  if (stopping) return
  stopping = true
  const done = { restored: modeBefore === undefined ? null : false, revoked: install ? false : null }
  try {
    if (modeBefore && access) {
      if (access.expiresAt - Date.now() < 60_000) await mint().catch(() => undefined)
      const r = await api("PUT", "/v1/cloud/inference-gateway", { mode: modeBefore.mode, machine: modeBefore.machine })
      done.restored = r.status >= 200 && r.status < 300
      say(done.restored ? `team mode restored to ${modeBefore.mode}` : `could not restore the team mode: HTTP ${r.status} ${plainCode(r.json)}`)
    }
  } catch (e) {
    say(`could not restore the team mode: ${(e as Error).message}`)
  }
  await stopChild(gateway)
  await stopChild(stub)
  if (install && stack) {
    done.revoked = await op("install.revoke", { install }).then(() => true, () => false)
    say(done.revoked ? "revoked the gateway's cmux install" : "could not revoke the gateway's cmux install")
  }
  if (stack) {
    await call(`${STACK_API}/auth/sessions/current`, {
      method: "DELETE",
      headers: { ...STACK_HEADERS, "x-stack-access-token": stack.access, "x-stack-refresh-token": stack.refresh },
    }).catch(() => undefined)
  }
  writeJson("done.json", done)
}

const main = async () => {
  const email = process.env.CMUX_UITEST_STACK_EMAIL ?? ""
  const password = process.env.CMUX_UITEST_STACK_PASSWORD ?? ""
  if (!email || !password) throw new Error("CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD must be set")
  const signIn = await call(`${STACK_API}/auth/password/sign-in`, { method: "POST", headers: STACK_HEADERS, body: { email, password } })
  if (signIn.status !== 200 || typeof signIn.json?.access_token !== "string") throw refused("stack sign-in", signIn)
  stack = { access: signIn.json.access_token, refresh: String(signIn.json.refresh_token ?? "") }
  user = String((await op("user.ensure", {}))?.id ?? "")
  keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey
  install = String(
    (await op("install.register", {
      public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
      kind: "cli",
      name: `zero-to-agents gateway ${process.env.GITHUB_RUN_ID ?? "local"}`.slice(0, 80),
      device_name: "zero-to-agents runner",
      platform: "linux",
    }))?.id ?? "",
  )
  const first = await mint()
  say(`install token ready (team ${first.team.replace(/[^A-Za-z0-9_-]/g, "") || "?"}, lifetime ${first.ttl} s)`)

  const before = await api("GET", "/v1/cloud/inference-gateway")
  if (before.status !== 200) throw refused("gateway status", before)
  modeBefore = {
    mode: String(before.json?.gateway?.mode ?? "off"),
    machine: typeof before.json?.gateway?.machine === "string" ? before.json.gateway.machine : null,
  }

  // The person's own proxy: the shared model stub, on loopback.
  const nonce = crypto.randomUUID().replace(/-/g, "").slice(0, 12)
  const ready = path.join(dir, "stub.ready")
  stub = spawn("python3", [stubPy, "--port", "0", "--nonce", nonce, "--log", path.join(dir, "stub.log"), "--ready-file", ready], {
    stdio: ["ignore", "ignore", "ignore"],
  })
  let port = 0
  for (let i = 0; i < 50 && !port; i++) {
    if (existsSync(ready)) port = Number(JSON.parse(readFileSync(ready, "utf8")).port) || 0
    else await Bun.sleep(200)
  }
  if (!port) throw new Error("the model stub did not start")

  const set = await api("PUT", "/v1/cloud/inference-gateway", { mode: "joined", machine: null })
  if (set.status < 200 || set.status >= 300) throw refused("set mode joined", set)
  say(`team mode joined (was ${modeBefore.mode})`)

  const log = openSync(path.join(dir, "gateway.log"), "a")
  gateway = spawn(cmux, ["inference", "gateway", "--api", DEV_API, "--upstream", `http://127.0.0.1:${port}`, "--token-file", path.join(dir, "token")], {
    stdio: ["ignore", log, log],
    env: { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: dir },
  })
  closeSync(log)
  const t0 = Date.now()
  let online = false
  while (Date.now() - t0 < ONLINE_LIMIT_MS && gateway.exitCode === null) {
    const g = await api("GET", "/v1/cloud/inference-gateway")
    if (g.json?.gateway?.online === true && g.json?.gateway?.mode === "joined") {
      online = true
      break
    }
    await Bun.sleep(1_000)
  }
  if (!online) throw new Error(`the gateway did not come online in mode joined within ${ONLINE_LIMIT_MS / 1000} s`)
  say(`gateway online in ${Math.round((Date.now() - t0) / 1000)} s, in front of the stub at 127.0.0.1:${port}`)
  writeJson("ready.json", { team: first.team, mode_before: modeBefore.mode, nonce, online_s: Math.round((Date.now() - t0) / 1000) })

  // Keep the token fresh for the gateway's reconnects until asked to stop.
  while (!stopping) {
    await Bun.sleep(Math.max(10_000, Math.min(120_000, access!.expiresAt - Date.now() - 90_000)))
    if (!stopping && access!.expiresAt - Date.now() < 120_000) await mint().catch((e) => say(`token refresh failed: ${(e as Error).message}`))
  }
}

process.on("SIGTERM", () => void cleanup().then(() => process.exit(0)))
setTimeout(() => void cleanup().then(() => process.exit(0)), DEADLINE_MS).unref()
main().catch(async (e) => {
  say(`failed: ${(e as Error).message}`)
  writeJson("ready.json", { error: (e as Error).message.replace(/[^A-Za-z0-9 _.:/()-]/g, " ").slice(0, 200) })
  await cleanup()
  process.exit(1)
})
