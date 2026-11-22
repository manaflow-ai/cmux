import type { Env } from "./env";
import { ApiError, unauthorized } from "./errors";

/**
 * Machine sign-in (PROTOCOL.md, Machine sign-in): a machine the person joined
 * to cmux (`acpmux host join`) keeps a cmux-platform machine credential, not
 * the person's Stack token. `POST /v1/auth/machine` asks cmux-platform who that
 * credential belongs to (`GET /v1/machines/credentials/self`, with the
 * credential as its bearer) and signs the machine in as that person. The hub
 * trusts only the platform's answer, from an origin it is configured with,
 * never anything the machine says about itself.
 *
 * cmux-platform names the person by a one-way id (`user_` and 20 hex of
 * sha256("stack:<project>:<sub>"), cmux-platform src/server/auth/Ids.ts), so
 * the hub records that id beside its own `<project>:<sub>` at every Stack
 * sign-in and looks it up here: a person who never signed in to the hub has no
 * account on it to join a machine to.
 */

const DEFAULT_TIMEOUT_MS = 5000;
const PLATFORM_USER_ID = /^user_[0-9a-f]{20}$/;
/** A machine credential as cmux-platform issues it (`cmm_...`); bounded so a junk body costs nothing. */
const MAX_CREDENTIAL = 512;

/** cmux-platform's public user id for a Stack identity. */
export async function platformUserIdFor(projectId: string, sub: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`stack:${projectId}:${sub}`));
  const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  return `user_${hex.slice(0, 20)}`;
}

/** `MACHINE_ORIGINS`: comma list of `<stackProjectId>=<cmux-platform https origin>`; invalid pairs are skipped. */
export function machineOrigins(env: Pick<Env, "MACHINE_ORIGINS">): { projectId: string; origin: string }[] {
  const out: { projectId: string; origin: string }[] = [];
  for (const pair of (env.MACHINE_ORIGINS ?? "").split(",")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    const projectId = pair.slice(0, eq).trim();
    const origin = pair.slice(eq + 1).trim().replace(/\/+$/, "");
    try {
      // Exactly an https origin: no path, query, fragment or credentials.
      const u = new URL(origin);
      if (projectId && u.protocol === "https:" && u.origin === origin) out.push({ projectId, origin });
    } catch {
      // skipped
    }
  }
  return out;
}

function timeoutMs(env: Pick<Env, "MACHINE_TIMEOUT_MS">): number {
  const v = Number(env.MACHINE_TIMEOUT_MS);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_TIMEOUT_MS;
}

export interface VerifiedMachine {
  projectId: string;
  platformUserId: string;
  machineId: string;
  /** The team the machine was joined to. */
  teamId: string;
  /** When the credential expires (ms). */
  expiresAt: number;
}

/** The person and machine cmux-platform says `credential` belongs to; 401 when no configured platform accepts it. */
export async function verifyMachineCredential(credential: string, env: Env, now: number): Promise<VerifiedMachine> {
  if (credential.length > MAX_CREDENTIAL || /\s/.test(credential)) throw unauthorized("machine credential not accepted");
  const origins = machineOrigins(env);
  if (!origins.length) throw new ApiError(503, "machine_auth_unavailable", "this hub signs in no joined machines yet");
  for (const { projectId, origin } of origins) {
    let res: Response;
    try {
      res = await fetch(`${origin}/v1/machines/credentials/self`, {
        headers: { authorization: `Bearer ${credential}`, accept: "application/json" },
        redirect: "manual",
        signal: AbortSignal.timeout(timeoutMs(env)),
      });
    } catch {
      continue;
    }
    if (!res.ok) continue;
    const body = (await res.json().catch(() => null)) as Record<string, unknown> | null;
    if (!body || typeof body.machineId !== "string" || !body.machineId || typeof body.teamId !== "string" || !body.teamId) continue;
    if (typeof body.userId !== "string" || !PLATFORM_USER_ID.test(body.userId)) {
      throw new ApiError(403, "machine_no_person", "this machine's join names no person; join it again");
    }
    const expiresAt = Date.parse(String(body.expiresAt));
    if (!Number.isFinite(expiresAt) || expiresAt <= now) throw unauthorized("machine credential expired");
    return { projectId, platformUserId: body.userId, machineId: body.machineId, teamId: body.teamId, expiresAt };
  }
  throw unauthorized("machine credential not accepted");
}

function aliasStub(env: Env, projectId: string, platformUserId: string) {
  // Its own User DO instance: no session ever names it (session users are `<project>:<sub>`),
  // and the Worker never forwards an /internal path.
  return env.USER_DO.get(env.USER_DO.idFromName(`machine-alias:${projectId}:${platformUserId}`));
}

/** Records the platform's id for the hub user `<projectId>:<sub>` (at Stack sign-in). */
export async function recordPlatformAlias(env: Env, projectId: string, sub: string): Promise<void> {
  const platformUserId = await platformUserIdFor(projectId, sub);
  await aliasStub(env, projectId, platformUserId).fetch(
    new Request("https://user.do/internal/machine-alias", { method: "PUT", body: JSON.stringify({ userId: `${projectId}:${sub}` }) }),
  );
}

/** The hub user cmux-platform's `platformUserId` is, if that person ever signed in to the hub. */
export async function hubUserFor(env: Env, projectId: string, platformUserId: string): Promise<string | null> {
  const res = await aliasStub(env, projectId, platformUserId).fetch(new Request("https://user.do/internal/machine-alias", { method: "GET" }));
  if (!res.ok) return null;
  const { userId } = (await res.json()) as { userId: string | null };
  return typeof userId === "string" && userId.startsWith(`${projectId}:`) ? userId : null;
}
