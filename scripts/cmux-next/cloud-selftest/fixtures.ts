/**
 * Test identities and teams for the self-test (plans/cmux-next/cloud-selftest-DESIGN.md §3). Three providers, one
 * interface:
 *
 * - `worker`: the cmux-api Worker's dev-only POST /v1/dev/fixtures (backend/apps/api/src/dev-fixtures.ts), which
 *   refuses outside development, preview and test and needs the DEV_FIXTURES_TOKEN secret. It also syncs the team into
 *   TeamDO at once, so a membership revoked mid-session is live on the next request.
 * - `stack`: the same calls straight to the sign-in service's server API with the dev project's server key
 *   (STACK_SECRET_SERVER_KEY), for a backend that has no fixtures route deployed. TeamDO then learns of a change from
 *   the service's webhook or the member's own user.teams.list heal (paced), so `synced` is false and a step that needs
 *   a live revoke waits for it (within_ms).
 * - `accounts`: pre-made accounts (email and password per actor) signed in with the password API; no team changes,
 *   so scenarios that need `fixtures.mutate` are skipped.
 *
 * Every user this makes is `selftest-<run>-<actor>@selftest.cmux.invalid` and marked (server metadata cmuxSelftest),
 * and cleanup deletes only users and teams that carry this run's mark. Tokens never reach the log (the run's secret list).
 */
import { createHash } from "node:crypto";
import { STACK, STACK_API } from "../cloud-journey";

export type Role = "owner" | "admin" | "member" | "billing" | "guest";
export type FixtureUser = { email: string; stack_user: string; access_token: string; refresh_token?: string };
export type FixtureTeam = { stack_team: string; team: string };

export interface Fixtures {
  readonly kind: "worker" | "stack" | "accounts";
  /** Whether team changes are possible (create, add, role, remove, revoke). */
  readonly mutable: boolean;
  /** Whether a membership change reaches TeamDO before the call returns. */
  readonly synced: boolean;
  user(actor: string): Promise<FixtureUser>;
  team(owner: FixtureUser, name: string): Promise<FixtureTeam>;
  setRole(team: FixtureTeam, user: FixtureUser, role: Exclude<Role, "owner">): Promise<void>;
  remove(team: FixtureTeam, user: FixtureUser): Promise<void>;
  /** End every sign-in session of the user (its refresh tokens stop working). */
  revokeSessions(user: FixtureUser): Promise<number>;
  cleanup(): Promise<{ users: number; teams: number }>;
}

export const SELFTEST_DOMAIN = "selftest.cmux.invalid";
export const selftestEmail = (run: string, actor: string) => `selftest-${run}-${actor}@${SELFTEST_DOMAIN}`.toLowerCase();
/** The role permissions the API maps to cmux roles (backend team-roles.ts STACK_ROLE_PERMISSIONS). */
export const ROLE_PERMISSION: Record<Exclude<Role, "owner" | "member">, string> = { admin: "cmux:admin", billing: "cmux:billing", guest: "cmux:guest" };
const hex20 = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 20);
/** backend domains/user.ts userIdFor / stackTeamIdFor: the cmux ids are derived, no lookup. */
export const cmuxUserId = (project: string, stackUser: string) => `user_${hex20(`stack:${project}:${stackUser}`)}`;
export const cmuxTeamId = (project: string, stackTeam: string) => `team_${hex20(`stack-team:${project}:${stackTeam}`)}`;

type Http = (method: string, url: string, body: unknown, headers: Record<string, string>) => Promise<{ status: number; body: any }>;
export const defaultHttp: Http = async (method, url, body, headers) => {
  const res = await fetch(url, { method, headers: { "content-type": "application/json", ...headers }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
  const text = await res.text();
  let parsed: any = {};
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text.slice(0, 200) };
  }
  return { status: res.status, body: parsed };
};

/** The sign-in service's server API, dev project only: the production project is refused before any call. */
export function stackFixtures(run: string, serverKey: string, secrets: string[], http: Http = defaultHttp, project: string = STACK.dev.project): Fixtures {
  if (project !== STACK.dev.project) throw new Error("fixtures.refused: the stack provider runs only against the dev sign-in project");
  if (!serverKey) throw new Error("fixtures.not_configured: no STACK_SECRET_SERVER_KEY for the dev project");
  secrets.push(serverKey);
  const headers = { "x-stack-access-type": "server", "x-stack-project-id": project, "x-stack-secret-server-key": serverKey };
  const call = async (method: string, route: string, body?: unknown, okStatuses = [200, 201], okCodes: string[] = []): Promise<any> => {
    const r = await http(method, `${STACK_API}/api/v1${route}`, body ?? (method === "GET" ? undefined : {}), headers);
    // Never echo the service's body (user data); its known-error code is enough.
    if (okCodes.includes(String(r.body?.code ?? ""))) return null;
    if (r.status === 404 && String(r.body?.code ?? "") === "PERMISSION_NOT_FOUND") throw new Error(`fixtures.role_unavailable: the sign-in project defines no ${decodeURIComponent(route.split("/").pop() ?? "")} team permission`);
    if (!okStatuses.includes(r.status)) throw new Error(`fixtures.stack: ${method} ${route.split("?")[0]} HTTP ${r.status} ${String(r.body?.code ?? "")}`);
    return r.body;
  };
  const users = new Map<string, FixtureUser>();
  const teams: FixtureTeam[] = [];
  return {
    kind: "stack",
    mutable: true,
    synced: false,
    async user(actor) {
      const email = selftestEmail(run, actor);
      const u = await call("POST", "/users", { primary_email: email, primary_email_verified: true, primary_email_auth_enabled: false, display_name: `Self-test ${actor}`, server_metadata: { cmuxSelftest: run } });
      const s = await call("POST", "/auth/sessions", { user_id: u.id, expires_in_millis: 2 * 3600_000 });
      secrets.push(s.access_token, s.refresh_token);
      const out = { email, stack_user: String(u.id), access_token: String(s.access_token), refresh_token: String(s.refresh_token) };
      users.set(out.stack_user, out);
      return out;
    },
    async team(owner, name) {
      const t = await call("POST", "/teams", { display_name: name, creator_user_id: owner.stack_user, server_metadata: { cmuxSelftest: run } });
      const team = { stack_team: String(t.id), team: cmuxTeamId(project, String(t.id)) };
      teams.push(team);
      return team;
    },
    async setRole(team, user, role) {
      mustOwn(users, teams, team, user);
      await call("POST", `/team-memberships/${team.stack_team}/${user.stack_user}`, {}, [200, 201, 409]);
      for (const [r, perm] of Object.entries(ROLE_PERMISSION)) {
        if (r === role) await call("POST", `/team-permissions/${team.stack_team}/${user.stack_user}/${encodeURIComponent(perm)}`, {}, [200, 201, 409]);
        // Not held, or not defined in this project: nothing to take away.
        else await call("DELETE", `/team-permissions/${team.stack_team}/${user.stack_user}/${encodeURIComponent(perm)}`, {}, [200, 404], ["TEAM_PERMISSION_NOT_FOUND", "PERMISSION_NOT_FOUND"]);
      }
    },
    async remove(team, user) {
      mustOwn(users, teams, team, user);
      await call("DELETE", `/team-memberships/${team.stack_team}/${user.stack_user}`, {}, [200, 404]);
    },
    async revokeSessions(user) {
      mustOwn(users, teams, null, user);
      const r = await call("GET", `/auth/sessions?user_id=${encodeURIComponent(user.stack_user)}`);
      let n = 0;
      for (const s of r.items ?? []) {
        await call("DELETE", `/auth/sessions/${encodeURIComponent(s.id)}?user_id=${encodeURIComponent(user.stack_user)}`, {}, [200, 404]);
        n++;
      }
      return n;
    },
    async cleanup() {
      let t = 0;
      let u = 0;
      for (const team of teams.splice(0)) {
        const got = await http("GET", `${STACK_API}/api/v1/teams/${team.stack_team}`, undefined, headers);
        if (got.status === 200 && got.body?.server_metadata?.cmuxSelftest === run) {
          await call("DELETE", `/teams/${team.stack_team}`, {}, [200, 404]);
          t++;
        }
      }
      for (const user of [...users.values()]) {
        const got = await http("GET", `${STACK_API}/api/v1/users/${user.stack_user}`, undefined, headers);
        if (got.status === 200 && got.body?.server_metadata?.cmuxSelftest === run && String(got.body?.primary_email ?? "").endsWith(`@${SELFTEST_DOMAIN}`)) {
          await call("DELETE", `/users/${user.stack_user}`, {}, [200, 404]);
          u++;
        }
        users.delete(user.stack_user);
      }
      return { users: u, teams: t };
    },
  };
}

/** Only users and teams this run made may be changed (never a real account picked by id). */
function mustOwn(users: Map<string, FixtureUser>, teams: FixtureTeam[], team: FixtureTeam | null, user: FixtureUser): void {
  if (!users.has(user.stack_user)) throw new Error("fixtures.refused: not a user this run made");
  if (team && !teams.some((t) => t.stack_team === team.stack_team)) throw new Error("fixtures.refused: not a team this run made");
}

/** The Worker's dev-only route (backend/apps/api/src/dev-fixtures.ts): same calls, and it syncs TeamDO before it answers. */
export function workerFixtures(run: string, api: string, token: string, secrets: string[], http: Http = defaultHttp): Fixtures {
  if (!token) throw new Error("fixtures.not_configured: no DEV_FIXTURES_TOKEN for the fixtures route");
  secrets.push(token);
  const call = async (op: string, params: Record<string, unknown>): Promise<any> => {
    const r = await http("POST", `${api}/v1/dev/fixtures`, { op, run, ...params }, { "x-cmux-dev-fixtures": token });
    if (r.status !== 200 || r.body?.ok !== true) throw new Error(`${String(r.body?.error?.code ?? `fixtures.http_${r.status}`)}: ${op} ${String(r.body?.error?.message ?? "")}`);
    return r.body.value;
  };
  return {
    kind: "worker",
    mutable: true,
    synced: true,
    async user(actor) {
      const v = await call("user", { actor });
      secrets.push(v.access_token, v.refresh_token ?? "");
      return { email: v.email, stack_user: v.stack_user, access_token: v.access_token, refresh_token: v.refresh_token };
    },
    async team(owner, name) {
      const v = await call("team", { owner: owner.stack_user, display_name: name });
      return { stack_team: v.stack_team, team: v.team };
    },
    async setRole(team, user, role) {
      await call("member.set", { stack_team: team.stack_team, stack_user: user.stack_user, role });
    },
    async remove(team, user) {
      await call("member.remove", { stack_team: team.stack_team, stack_user: user.stack_user });
    },
    async revokeSessions(user) {
      return Number((await call("sessions.revoke", { stack_user: user.stack_user })).revoked ?? 0);
    },
    async cleanup() {
      return call("cleanup", {});
    },
  };
}

/** Pre-made accounts ({actor: {email, password}}): signed in, never changed. */
export function accountFixtures(accounts: Record<string, { email: string; password: string }>, secrets: string[], http: Http = defaultHttp): Fixtures {
  const refuse = async (): Promise<never> => {
    throw new Error("fixtures.read_only: the accounts provider cannot change teams; use --fixtures worker or stack");
  };
  return {
    kind: "accounts",
    mutable: false,
    synced: false,
    async user(actor) {
      const a = accounts[actor];
      if (!a) throw new Error(`fixtures.no_account: no account for actor ${actor}`);
      secrets.push(a.password);
      const r = await http("POST", `${STACK_API}/api/v1/auth/password/sign-in`, { email: a.email, password: a.password }, {
        "x-stack-access-type": "client",
        "x-stack-project-id": STACK.dev.project,
        "x-stack-publishable-client-key": STACK.dev.clientKey,
      });
      if (r.status !== 200 || typeof r.body.access_token !== "string") throw new Error(`fixtures.sign_in: HTTP ${r.status} ${String(r.body?.code ?? "")}`);
      secrets.push(r.body.access_token, r.body.refresh_token ?? "");
      return { email: a.email, stack_user: String(r.body.user_id ?? ""), access_token: r.body.access_token, refresh_token: r.body.refresh_token };
    },
    team: refuse,
    setRole: refuse,
    remove: refuse,
    revokeSessions: refuse,
    async cleanup() {
      return { users: 0, teams: 0 };
    },
  };
}

/** The sign-in service's refresh with a refresh token: the access token, or the refusal's status. */
export async function refreshSession(refreshToken: string, http: Http = defaultHttp): Promise<{ ok: true; access_token: string } | { ok: false; status: number; code: string }> {
  const r = await http("POST", `${STACK_API}/api/v1/auth/sessions/current/refresh`, {}, {
    "x-stack-access-type": "client",
    "x-stack-project-id": STACK.dev.project,
    "x-stack-publishable-client-key": STACK.dev.clientKey,
    "x-stack-refresh-token": refreshToken,
  });
  if (r.status === 200 && typeof r.body?.access_token === "string") return { ok: true, access_token: r.body.access_token };
  return { ok: false, status: r.status, code: String(r.body?.code ?? `http.${r.status}`) };
}
