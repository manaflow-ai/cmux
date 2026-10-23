import { getStackServerApp } from "../../app/lib/stack";
import { isRunCloudOperationPending, parseRunCloudResponse, RunCloudOperationPending, RunCloudHttpError } from "./cloudClientContract";

export { isRunCloudOperationPending, RunCloudOperationPending } from "./cloudClientContract";

/** The Cloud deployments the Run worker may call, by Vercel project. Keep in
 * step with scripts/cloud-vm/projects.mjs (a test checks they agree). */
const RUN_CLOUD_ORIGIN_BY_PROJECT: ReadonlyMap<string, string> = new Map([
  ["prj_804LTAUdOwulMvEfcmfnU8bvGo3T", "https://cmux-staging.vercel.app"],
  ["prj_kH8qcuoliyJ2TLI4vMM03rnNVzr4", "https://cmux.com"],
]);

/** Never derive the credential destination from a request Host header. On a
 * Cloud deployment the fixed project ID picks the origin: Vercel sets
 * VERCEL_PROJECT_PRODUCTION_URL to the project's shortest production domain,
 * which on staging is not the origin the Run API is served from. */
export function runCloudOrigin(): string {
  const project = process.env.VERCEL_PROJECT_ID;
  if (project) {
    const origin = RUN_CLOUD_ORIGIN_BY_PROJECT.get(project);
    if (!origin) throw new Error("Run worker requires a recognized Cloud deployment");
    return origin;
  }
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
    const payload = parseRunCloudResponse({ method, ok: response.ok, status: response.status, text: await response.text() });
    if (!response.ok && isRunCloudOperationPending(payload)) throw new RunCloudOperationPending();
    if (!response.ok && !(method === "DELETE" && response.status === 404)) throw new RunCloudHttpError(method, response.status, payload);
    if (method === "DELETE" && response.status === 404) return {};
    return payload;
  };
}
