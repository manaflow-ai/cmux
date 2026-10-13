import { createLocalJWKSet, createRemoteJWKSet, decodeJwt, jwtVerify, type JWK, type JWTVerifyGetKey } from "jose"
import type { Env } from "./env.ts"

const STACK_API = "https://api.stack-auth.com"

/** One Stack project whose users the Worker accepts (an entry of STACK_PROJECTS). */
export interface StackProject {
  readonly id: string
  /** "dev" or "prod"; for logs only. */
  readonly label: string
  /** Sent on client-API calls when non-empty (production needs none). */
  readonly publishableClientKey: string
  /** Where a team invitation email links to (a trusted domain of this project). */
  readonly inviteCallbackUrl: string
}

const parsed = new Map<string, ReadonlyArray<StackProject>>()
/** The configured projects, primary first. Throws on a malformed config (a deploy error, not a caller error). */
export const stackProjects = (env: Env): ReadonlyArray<StackProject> => {
  let list = parsed.get(env.STACK_PROJECTS)
  if (!list) {
    const raw = JSON.parse(env.STACK_PROJECTS) as Array<Partial<StackProject>>
    if (!Array.isArray(raw) || raw.length === 0) throw new Error("STACK_PROJECTS must be a non-empty array")
    list = raw.map((p) => {
      if (typeof p.id !== "string" || !p.id) throw new Error("STACK_PROJECTS entry without id")
      return { id: p.id, label: p.label ?? p.id, publishableClientKey: p.publishableClientKey ?? "", inviteCallbackUrl: p.inviteCallbackUrl ?? "" }
    })
    parsed.set(env.STACK_PROJECTS, list)
  }
  return list
}

export const primaryProject = (env: Env): StackProject => stackProjects(env)[0]!
export const projectById = (env: Env, id: string): StackProject | undefined => stackProjects(env).find((p) => p.id === id)

export interface Caller {
  /** The verified JWT `sub`. Unique within its project; pair it with `projectId` wherever identity matters. */
  readonly userId: string
  /** The Stack project that issued the token (one of STACK_PROJECTS). */
  readonly projectId: string
  /** The raw Stack access token, used for client-API membership checks when no server key exists. */
  readonly token: string
}

const issuerOf = (projectId: string) => `${STACK_API}/api/v1/projects/${projectId}`

const keySets = new Map<string, JWTVerifyGetKey>()
const stackKeys = (env: Env, projectId: string): JWTVerifyGetKey => {
  if (env.ENVIRONMENT === "test" && env.STACK_TEST_JWKS) return createLocalJWKSet(JSON.parse(env.STACK_TEST_JWKS) as { keys: Array<JWK> })
  let keys = keySets.get(projectId)
  if (!keys) {
    keys = createRemoteJWKSet(new URL(`${issuerOf(projectId)}/.well-known/jwks.json`), { cacheMaxAge: 10 * 60_000, cooldownDuration: 30_000 })
    keySets.set(projectId, keys)
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

/**
 * Verifies a Stack access token from any configured project. The unverified `iss` only picks which
 * project's JWKS to try; the signature, issuer and audience are then checked against that project, so a
 * token never verifies under another project's keys or claims.
 */
export const verifyStackToken = async (env: Env, token: string): Promise<Caller | undefined> => {
  if (!token) return undefined
  const projects = stackProjects(env)
  try {
    const iss = decodeJwt(token).iss
    const project = projects.find((p) => issuerOf(p.id) === iss)
    if (!project) return undefined
    const { payload } = await jwtVerify(token, stackKeys(env, project.id), {
      algorithms: ["ES256"],
      issuer: issuerOf(project.id),
      audience: project.id,
      clockTolerance: 60
    })
    if (typeof payload.sub !== "string" || !payload.sub || payload.is_anonymous === true) return undefined
    return { userId: payload.sub, projectId: project.id, token }
  } catch {
    return undefined
  }
}
