import type { Caller } from "./auth.ts"
import type { Env } from "./env.ts"

const API = "https://api.stack-auth.com/api/v1"

/**
 * Stack headers: the server key when the Worker has one (STACK_SECRET_SERVER_KEY), otherwise the
 * caller's own access token on the client API. Both can list a user's teams and send invitations.
 */
const headers = (env: Env, caller: Caller): Record<string, string> =>
  env.STACK_SECRET_SERVER_KEY
    ? { "content-type": "application/json", "x-stack-access-type": "server", "x-stack-project-id": env.STACK_PROJECT_ID, "x-stack-secret-server-key": env.STACK_SECRET_SERVER_KEY }
    : {
        "content-type": "application/json",
        "x-stack-access-type": "client",
        "x-stack-project-id": env.STACK_PROJECT_ID,
        // Production needs no publishable key (as in CmuxAuthRuntime AuthConfig); send it only when set.
        ...(env.STACK_PUBLISHABLE_CLIENT_KEY ? { "x-stack-publishable-client-key": env.STACK_PUBLISHABLE_CLIENT_KEY } : {}),
        "x-stack-access-token": caller.token
      }

/** The team ids the caller belongs to now. Throws when Stack cannot answer (never treated as "not a member" silently). */
export const userTeams = async (env: Env, caller: Caller): Promise<ReadonlyArray<string>> => {
  if (env.ENVIRONMENT === "test") {
    const teams = JSON.parse(env.STACK_TEST_TEAMS ?? "{}") as Record<string, Array<string>>
    return teams[caller.userId] ?? []
  }
  const who = env.STACK_SECRET_SERVER_KEY ? encodeURIComponent(caller.userId) : "me"
  const res = await fetch(`${API}/teams?user_id=${who}`, { headers: headers(env, caller), signal: AbortSignal.timeout(10_000) })
  // Never echo Stack's body: it can carry user data.
  if (!res.ok) throw new Error(`stack GET teams returned ${res.status}`)
  const body = (await res.json()) as { items?: Array<{ id?: unknown }> }
  if (!Array.isArray(body.items)) throw new Error("stack GET teams: no items")
  return body.items.flatMap((t) => (typeof t.id === "string" ? [t.id] : []))
}

export type InviteResult = { ok: true; url: string } | { ok: false; status: number; code: string }

/** Sends a Stack team invitation email; the email links to INVITE_CALLBACK_URL with the invitation code. */
export const sendTeamInvite = async (env: Env, caller: Caller, teamId: string, email: string): Promise<InviteResult> => {
  if (env.ENVIRONMENT === "test") return { ok: true, url: env.INVITE_CALLBACK_URL }
  const res = await fetch(`${API}/team-invitations/send-code`, {
    method: "POST",
    headers: headers(env, caller),
    body: JSON.stringify({ team_id: teamId, email, callback_url: env.INVITE_CALLBACK_URL }),
    signal: AbortSignal.timeout(10_000)
  })
  if (res.ok) return { ok: true, url: env.INVITE_CALLBACK_URL }
  return { ok: false, status: res.status, code: res.headers.get("x-stack-known-error") ?? "stack_error" }
}
