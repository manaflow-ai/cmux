import { getStackServerApp } from "../../app/lib/stack";

/** Never derive the credential destination from a request Host header. */
export function runCloudOrigin(): string {
  const configured = process.env.VERCEL_PROJECT_PRODUCTION_URL;
  const host = configured?.replace(/^https:\/\//, "") ?? "cmux.com";
  if (host !== "cmux.com" && host !== "cmux-staging.vercel.app") throw new Error("Run worker requires a recognized Cloud deployment");
  return `https://${host}`;
}

/** The redacted setup step that failed. The provider's own message is never
 * kept, so the stage is the only detail that may reach a durable receipt. */
export type RunSessionSetupStage = "owner-lookup" | "session-create" | "session-tokens" | "cloud-origin";
export class RunSessionSetupError extends Error {
  constructor(readonly stage: RunSessionSetupStage) {
    super(`Run worker setup failed at ${stage}`);
  }
}

async function setupStep<T>(stage: RunSessionSetupStage, step: () => T | Promise<T>): Promise<T> {
  try {
    return await step();
  } catch {
    throw new RunSessionSetupError(stage);
  }
}

export type RunCloudClient = (method: string, path: string, body?: unknown, idempotencyKey?: string) => Promise<Record<string, unknown>>;

/** A fresh, short-lived session reuses current membership/entitlement checks.
 * No caller token is stored in the queue, events, artifacts, or checkpoints. */
export async function runCloudClient(userId: string, ownerTeamId: string): Promise<RunCloudClient> {
  const user = await setupStep("owner-lookup", () => getStackServerApp().getUser(userId));
  if (!user) throw new RunSessionSetupError("owner-lookup");
  const session = await setupStep("session-create", () => user.createSession({ expiresInMillis: 20 * 60_000, isImpersonation: true }));
  const tokens = await setupStep("session-tokens", () => session.getTokens());
  if (!tokens.accessToken || !tokens.refreshToken) throw new RunSessionSetupError("session-tokens");
  const { accessToken, refreshToken } = tokens;
  const origin = await setupStep("cloud-origin", runCloudOrigin);
  return async (method, path, body, key) => {
    if (!path.startsWith("/api/vm") || path.startsWith("//")) throw new Error("Invalid Run worker operation");
    const headers = new Headers({ authorization: `Bearer ${accessToken}`, "x-stack-refresh-token": refreshToken, "x-cmux-team-id": ownerTeamId, "content-type": "application/json", "x-cmux-client-timeout-ms": "950000" });
    if (key) headers.set("idempotency-key", key);
    const response = await fetch(new URL(path, origin), { method, headers, body: body === undefined ? undefined : JSON.stringify(body), redirect: "error", signal: AbortSignal.timeout(950_000) });
    if (!response.ok && !(method === "DELETE" && response.status === 404)) throw new Error(`Cloud ${method} operation failed (${response.status})`);
    if (method === "DELETE" && response.status === 404) return {};
    return await response.json() as Record<string, unknown>;
  };
}
