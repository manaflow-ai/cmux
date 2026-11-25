// cmux-wdev-gateway: the public, authenticated front of the dev VM's tag stacks
// (scripts/cmux-next/cloud-dev-stack.sh public-setup deploys it; cmux-next-ios/SECURITY.md, "A tag stack's public
// origin"). Each stack with a public slot answers on https://api.<slot>.wdev.cmux.dev (the cmux API),
// mobile.<slot>... (the mobile Worker) and hub.<slot>... (the device hub). This Worker refuses every request that
// does not carry a credential it verified itself, then sends it through the Cloudflare Tunnel to the VM's router
// (a Workers VPC service binding, VM), which routes by the request's host to that slot's stack.
//
// A request is admitted when it carries one of:
//   - a Stack Auth access token of the development project (the one dev builds sign in to), in `Authorization:
//     Bearer`, a `bearer.<token>` WebSocket subprotocol, or the body of the hub's POST /v1/auth/stack, signed by
//     the project's key, unexpired, not anonymous or restricted, with a verified email in WDEV_ALLOWED_EMAIL_DOMAINS;
//   - a token the stack itself signed (the API's install tokens, the hub's sessions and tickets), verified against
//     that stack's public keys (the router's GET /__wdev/jwks), which it only issues to an admitted account.
// The only exceptions carry no data: GET /v1/health and the API's GET /v1/client-config and
// /.well-known/jwks.json. Everything else is 401 here, before the stack's unmerged code runs.

const HOST = /^(api|mobile|hub)\.(s[0-9]{1,3})\.wdev\.cmux\.dev$/
const STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const STACK_ISSUER = `https://api.stack-auth.com/api/v1/projects/${STACK_PROJECT}`
const STACK_JWKS = `${STACK_ISSUER}/.well-known/jwks.json`
const OPEN = [
  (svc, method, path) => method === "GET" && path === "/v1/health",
  (svc, method, path) => svc === "api" && method === "GET" && (path === "/v1/client-config" || path === "/.well-known/jwks.json"),
]
const KEYS_TTL_MS = 5 * 60_000
// A token whose key is not in the cached set refetches it at most this often per set: a flood of bad tokens never
// turns into a flood of key fetches (Stack would rate-limit the gateway, the VM would wake stacks).
const REFETCH_MIN_MS = 60_000
const keyCache = new Map()
const lastRefetch = new Map()
/** Tests start from an empty cache. */
export const clearKeyCache = () => {
  keyCache.clear()
  lastRefetch.clear()
}

/** Refetch a key set once its cached copy lacks this token's key, at most every REFETCH_MIN_MS. */
async function verifyRefetching(name, load, jwt, now) {
  const keys = await cachedKeys(name, load, now)
  if (await verifyWith(keys, jwt)) return true
  const known = jwt.header.kid && keys.some((k) => k.kid === jwt.header.kid)
  if (known || now - (lastRefetch.get(name) ?? -Infinity) < REFETCH_MIN_MS) return false
  lastRefetch.set(name, now)
  keyCache.delete(name)
  return verifyWith(await cachedKeys(name, load, now), jwt)
}

/** The kinds of token a stack issues that admit a request: the API's access tokens (aud "api"), the hub's sessions
 * (iss "device-hub") and its tickets (typ "dh-ticket"). Every other token the stack signs (OAuth state, model
 * gateway run tokens, free inference) never does, though its signature is the stack's. */
export function stackTokenKind(jwt) {
  const { header, claims } = jwt
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud]
  if ((header.typ ?? "JWT") === "JWT" && aud.length === 1 && aud[0] === "api" && typeof claims.sub === "string") return "api access token"
  if ((header.typ ?? "JWT") === "JWT" && claims.iss === "device-hub" && claims.aud === undefined && typeof claims.sub === "string") return "hub session"
  if (header.typ === "dh-ticket" && claims.iss === undefined && typeof claims.jti === "string") return "hub ticket"
  return undefined
}

const b64url = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0))
const text = (bytes) => new TextDecoder().decode(bytes)

/** The JWT's header and claims, or undefined when it is not a well-formed ES256 JWT. */
export function parseJwt(token) {
  const parts = typeof token === "string" ? token.split(".") : []
  if (parts.length !== 3) return undefined
  try {
    const header = JSON.parse(text(b64url(parts[0])))
    const claims = JSON.parse(text(b64url(parts[1])))
    if (header.alg !== "ES256" || typeof claims !== "object" || claims === null) return undefined
    return { header, claims, signed: new TextEncoder().encode(`${parts[0]}.${parts[1]}`), signature: b64url(parts[2]) }
  } catch {
    return undefined
  }
}

async function verifyWith(keys, jwt) {
  const candidates = keys.filter((k) => k.kty === "EC" && k.crv === "P-256" && (!jwt.header.kid || !k.kid || k.kid === jwt.header.kid))
  for (const jwk of candidates) {
    const { kty, crv, x, y } = jwk
    try {
      const key = await crypto.subtle.importKey("jwk", { kty, crv, x, y, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"])
      if (await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, jwt.signature, jwt.signed)) return true
    } catch {}
  }
  return false
}

async function cachedKeys(name, load, now) {
  const hit = keyCache.get(name)
  if (hit && now - hit.at < KEYS_TTL_MS) return hit.keys
  const keys = await load()
  keyCache.set(name, { at: now, keys })
  return keys
}

const allowedDomains = (env) =>
  new Set((env.WDEV_ALLOWED_EMAIL_DOMAINS ?? "manaflow.ai").split(",").map((d) => d.trim().toLowerCase()).filter(Boolean))

/** Why this token does not admit the request, or undefined when it does. */
export async function refusal(token, ctx) {
  const jwt = parseJwt(token)
  if (!jwt) return "not a signed token"
  const { claims } = jwt
  const nowS = Math.floor(ctx.now / 1000)
  if (typeof claims.exp !== "number" || claims.exp <= nowS) return "expired"
  if (typeof claims.nbf === "number" && claims.nbf > nowS + 60) return "not yet valid"
  if (claims.iss === STACK_ISSUER) {
    const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud]
    if (!aud.includes(STACK_PROJECT)) return "another Stack project"
    if (claims.is_anonymous === true || claims.is_restricted === true) return "anonymous or restricted account"
    const domain = typeof claims.email === "string" ? claims.email.split("@").pop().toLowerCase() : ""
    if (claims.email_verified !== true || !allowedDomains(ctx.env).has(domain)) return "an account outside the cmux team"
    // A key Stack added since the cached set: fetched again (rate-limited).
    return (await verifyRefetching("stack", ctx.stackKeys, jwt, ctx.now)) ? undefined : "bad signature"
  }
  // A token the stack signed: only the kinds that stand for a signed-in account, then its own public keys, from the
  // router (fetched again, rate-limited, when the slot's stack changed or made its keys since).
  if (!stackTokenKind(jwt)) return "not a kind of token that admits a request"
  return (await verifyRefetching(`stack:${ctx.slot}`, ctx.ownKeys, jwt, ctx.now)) ? undefined : "not signed by the Stack project or this stack"
}

/** The credential a request carries, read without consuming its body (the hub's auth body is re-sent). */
export async function credentialOf(request, svc, path) {
  const auth = request.headers.get("authorization") ?? ""
  if (/^bearer\s+/i.test(auth)) return { token: auth.replace(/^bearer\s+/i, "").trim() }
  const proto = (request.headers.get("sec-websocket-protocol") ?? "").split(",").map((s) => s.trim()).find((p) => p.startsWith("bearer."))
  if (proto) return { token: proto.slice(7) }
  const url = new URL(request.url)
  const ticket = url.searchParams.get("ticket") ?? url.searchParams.get("token")
  if (svc === "hub" && ticket) return { token: ticket }
  if (svc === "hub" && request.method === "POST" && path === "/v1/auth/stack") {
    const body = await request.text()
    let token
    try {
      token = JSON.parse(body)?.token
    } catch {}
    return { token, body }
  }
  return {}
}

const deny = (status, message) =>
  Response.json({ error: { code: status === 401 ? "unauthorized" : "not_found", message } }, { status, headers: { "cache-control": "no-store" } })

export async function handle(request, env, deps = {}) {
  const url = new URL(request.url)
  const match = HOST.exec(url.hostname.toLowerCase())
  if (!match || url.port) return deny(404, "not a cmux tag stack host")
  const [, svc, slot] = match
  const path = url.pathname
  // To the VM's router: the request URL's host is the Host it routes by (a Workers VPC binding sends it as Host).
  const forward = (body) =>
    env.VM.fetch(new Request(`http://${url.hostname}${path}${url.search}`, body === undefined ? request : new Request(request, { body })))
  // An open path is a plain request: one asking to upgrade (a WebSocket) needs a credential like any other.
  if (!request.headers.has("upgrade") && OPEN.some((open) => open(svc, request.method, path))) return forward()
  const credential = await credentialOf(request, svc, path)
  if (!credential.token) return deny(401, "a cmux account credential is required")
  const ctx = {
    env,
    slot,
    now: deps.now ?? Date.now(),
    stackKeys: deps.stackKeys ?? (async () => (await (await fetch(STACK_JWKS)).json()).keys ?? []),
    ownKeys:
      deps.ownKeys ??
      (async () => {
        const r = await env.VM.fetch(new Request(`http://api.${slot}.wdev.cmux.dev/__wdev/jwks`))
        return r.ok ? ((await r.json()).keys ?? []) : []
      }),
  }
  const why = await refusal(credential.token, ctx)
  if (why) return deny(401, `credential refused: ${why}`)
  return forward(credential.body)
}

export default { fetch: (request, env) => handle(request, env) }
