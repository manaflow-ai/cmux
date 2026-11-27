/**
 * A Stack session for the cmux VM API (workers/cmux-vm/src/auth/middleware.ts fromSession): password sign-in as an
 * agent test account, then the X-Cmux-Team-Id tenant from the user's Stack teams (cloud-start-bench.ts
 * pickVmApiTenant). A session holds every scope but admin (workers/cmux-vm/src/domain/scopes.ts SESSION_SCOPES), so a
 * check that needs vm:files or vm:terminal does not depend on which scopes a stored key was issued with.
 *
 * Kept import-light on purpose: cloud-vm-dogfood-journey.ts loads it, and cloud-journey.ts (which has the same
 * sign-in) pulls in the whole Cloud journey.
 */
import { pickVmApiTenant } from "./cloud-start-bench.ts";

const STACK_API = "https://api.stack-auth.com";
/** The Stack projects of the VM API origins (cloud-journey.ts STACK): staging signs in to dev, production to prod. */
const STACK_FOR_ORIGIN: Record<string, { project: string; clientKey: string }> = {
  "https://vm-staging.cmux.dev": { project: "454ecd03-1db2-4050-845e-4ce5b0cd9895", clientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g" },
};

export type StackVmSession = { access: string; team: string; via: string };

async function stackCall(method: string, path: string, headers: Record<string, string>, body?: unknown): Promise<{ status: number; body: any }> {
  const response = await fetch(`${STACK_API}${path}`, {
    method,
    headers: { ...headers, ...(body === undefined ? {} : { "content-type": "application/json" }) },
    body: body === undefined ? null : JSON.stringify(body),
    signal: AbortSignal.timeout(20_000),
  });
  const text = await response.text();
  let parsed: unknown = null;
  try {
    parsed = text === "" ? null : JSON.parse(text);
  } catch {
    parsed = null;
  }
  return { status: response.status, body: parsed ?? {} };
}

/** Signs in and picks the tenant; throws with the reason (never the password or a token) when either fails. */
export async function stackVmSession(vmOrigin: string, email: string, password: string): Promise<StackVmSession> {
  const stack = STACK_FOR_ORIGIN[vmOrigin];
  if (!stack) throw new Error(`no Stack project is known for ${vmOrigin}; session auth runs against ${Object.keys(STACK_FOR_ORIGIN).join(", ")}`);
  const client = { "x-stack-access-type": "client", "x-stack-project-id": stack.project, "x-stack-publishable-client-key": stack.clientKey };
  const signIn = await stackCall("POST", "/api/v1/auth/password/sign-in", client, { email, password });
  if (signIn.status !== 200 || typeof signIn.body.access_token !== "string") {
    throw new Error(`Stack sign-in HTTP ${signIn.status} ${String(signIn.body.code ?? "")}`.trim());
  }
  const access: string = signIn.body.access_token;
  const signed = { ...client, "x-stack-access-token": access };
  const teams = await stackCall("GET", "/api/v1/teams?user_id=me", signed);
  if (teams.status !== 200) throw new Error(`Stack GET /api/v1/teams?user_id=me: HTTP ${teams.status} ${String(teams.body.code ?? "")}`.trim());
  const me = await stackCall("GET", "/api/v1/users/me", signed).catch(() => null);
  const picked = pickVmApiTenant(teams.body, me?.status === 200 ? me.body.selected_team_id ?? me.body.selected_team?.id : null);
  if (picked.team === null) throw new Error(picked.why);
  return { access, team: picked.team, via: picked.via };
}
