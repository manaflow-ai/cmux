import { primaryProject, projectById, type Caller, type StackProject } from "./auth.ts"
import type { Env } from "./env.ts"

const API = "https://api.stack-auth.com/api/v1"

/** The caller's own project (verifyStackToken only admits configured projects). */
const projectOf = (env: Env, caller: Caller): StackProject => {
  const p = projectById(env, caller.projectId)
  if (!p) throw new Error("caller project is not configured")
  return p
}

/** The server key applies to the primary project only; other projects' users go through the client API. */
const usesServerKey = (env: Env, caller: Caller) => !!env.STACK_SECRET_SERVER_KEY && caller.projectId === primaryProject(env).id

/**
 * Stack headers for the caller's project: the server key when the Worker has one for it, otherwise the
 * caller's own access token on the client API. Both can list a user's teams and send invitations.
 */
const headers = (env: Env, caller: Caller): Record<string, string> => {
  const project = projectOf(env, caller)
  return usesServerKey(env, caller)
    ? { "content-type": "application/json", "x-stack-access-type": "server", "x-stack-project-id": project.id, "x-stack-secret-server-key": env.STACK_SECRET_SERVER_KEY! }
    : {
        "content-type": "application/json",
        "x-stack-access-type": "client",
        "x-stack-project-id": project.id,
        // Production needs no publishable key (as in CmuxAuthRuntime AuthConfig); send it only when set.
        ...(project.publishableClientKey ? { "x-stack-publishable-client-key": project.publishableClientKey } : {}),
        "x-stack-access-token": caller.token
      }
}

/** The team ids the caller belongs to now, in the caller's own project. Throws when Stack cannot answer (never treated as "not a member" silently). */
export const userTeams = async (env: Env, caller: Caller): Promise<ReadonlyArray<string>> => {
  if (env.ENVIRONMENT === "test") {
    const teams = JSON.parse(env.STACK_TEST_TEAMS ?? "{}") as Record<string, Array<string>>
    const key = caller.projectId === primaryProject(env).id ? caller.userId : `${caller.projectId}:${caller.userId}`
    return teams[key] ?? []
  }
  const who = usesServerKey(env, caller) ? encodeURIComponent(caller.userId) : "me"
  const res = await fetch(`${API}/teams?user_id=${who}`, { headers: headers(env, caller), signal: AbortSignal.timeout(10_000) })
  // Never echo Stack's body: it can carry user data.
  if (!res.ok) throw new Error(`stack GET teams returned ${res.status}`)
  const body = (await res.json()) as { items?: Array<{ id?: unknown }> }
  if (!Array.isArray(body.items)) throw new Error("stack GET teams: no items")
  return body.items.flatMap((t) => (typeof t.id === "string" ? [t.id] : []))
}

export type InviteResult = { ok: true; url: string } | { ok: false; status: number; code: string }

/** Sends a Stack team invitation email from the caller's project; the email links to that project's invite callback with the code. */
export const sendTeamInvite = async (env: Env, caller: Caller, teamId: string, email: string): Promise<InviteResult> => {
  const callback = projectOf(env, caller).inviteCallbackUrl
  if (env.ENVIRONMENT === "test") return { ok: true, url: callback }
  const res = await fetch(`${API}/team-invitations/send-code`, {
    method: "POST",
    headers: headers(env, caller),
    body: JSON.stringify({ team_id: teamId, email, callback_url: callback }),
    signal: AbortSignal.timeout(10_000)
  })
  if (res.ok) return { ok: true, url: callback }
  return { ok: false, status: res.status, code: res.headers.get("x-stack-known-error") ?? "stack_error" }
}
