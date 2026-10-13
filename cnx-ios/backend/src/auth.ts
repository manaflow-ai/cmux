import { createLocalJWKSet, createRemoteJWKSet, jwtVerify, type JWK, type JWTVerifyGetKey } from "jose"
import type { Env } from "./env.ts"

const STACK_API = "https://api.stack-auth.com"

export interface Caller {
  readonly userId: string
  /** The raw Stack access token, used for client-API membership checks when no server key exists. */
  readonly token: string
}

const keySets = new Map<string, JWTVerifyGetKey>()
const stackKeys = (env: Env): JWTVerifyGetKey => {
  if (env.ENVIRONMENT === "test" && env.STACK_TEST_JWKS) return createLocalJWKSet(JSON.parse(env.STACK_TEST_JWKS) as { keys: Array<JWK> })
  let keys = keySets.get(env.STACK_PROJECT_ID)
  if (!keys) {
    keys = createRemoteJWKSet(new URL(`${STACK_API}/api/v1/projects/${env.STACK_PROJECT_ID}/.well-known/jwks.json`), { cacheMaxAge: 10 * 60_000, cooldownDuration: 30_000 })
    keySets.set(env.STACK_PROJECT_ID, keys)
  }
  return keys
}

/** Bearer header, or the `bearer.<token>` WebSocket subprotocol (PROTOCOL.md "Identity and auth"). */
export const bearerOf = (req: Request): { token: string; viaSubprotocol: boolean } | undefined => {
  const h = req.headers.get("authorization")
  if (h?.toLowerCase().startsWith("bearer ")) return { token: h.slice(7).trim(), viaSubprotocol: false }
  const protos = (req.headers.get("sec-websocket-protocol") ?? "").split(",").map((s) => s.trim())
  const b = protos.find((p) => p.startsWith("bearer."))
  return b ? { token: b.slice(7), viaSubprotocol: true } : undefined
}

export const verifyStackToken = async (env: Env, token: string): Promise<Caller | undefined> => {
  if (!token) return undefined
  try {
    const { payload } = await jwtVerify(token, stackKeys(env), {
      algorithms: ["ES256"],
      issuer: `${STACK_API}/api/v1/projects/${env.STACK_PROJECT_ID}`,
      audience: env.STACK_PROJECT_ID,
      clockTolerance: 60
    })
    if (typeof payload.sub !== "string" || !payload.sub || payload.is_anonymous === true) return undefined
    return { userId: payload.sub, token }
  } catch {
    return undefined
  }
}
