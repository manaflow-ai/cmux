import { stackApiBaseURL } from "../auth/stackApiBaseURL";
import { withStackAuthSpan } from "../auth/stackTelemetry";

/**
 * Stack's invitation-code endpoints, called as the signed-in user.
 *
 * The SDK's `acceptTeamInvitation(code)` runs on the app's own cookie token
 * store, so it cannot act for a native bearer request, and its
 * `getTeamInvitationDetails(code)` drops the team id that the endpoint
 * returns. Role application must know exactly which team the code joins, so
 * this calls the same endpoints the SDK calls, with the same client headers
 * and the caller's access token.
 */
export type InvitationCodeFailure = "email_mismatch" | "invalid" | "unavailable";

export type InvitationCodeResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly failure: InvitationCodeFailure };

export type InvitationCodeClient = {
  details(code: string, accessToken: string): Promise<InvitationCodeResult<{ teamId: string; teamDisplayName: string }>>;
  accept(code: string, accessToken: string): Promise<InvitationCodeResult<null>>;
};

type Environment = Record<string, string | undefined>;
type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export function createInvitationCodeClient(
  options: { readonly environment?: Environment; readonly fetch?: FetchLike } = {},
): InvitationCodeClient {
  const environment = options.environment ?? process.env;
  const fetcher = options.fetch ?? ((input, init) => fetch(input, init));

  async function call(path: string, code: string, accessToken: string): Promise<InvitationCodeResult<unknown>> {
    const projectId = environment.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
    const publishableKey = environment.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY?.trim();
    if (!projectId || !publishableKey) return { ok: false, failure: "unavailable" };
    let response: Response;
    try {
      response = await withStackAuthSpan("team_invitation_code", () => fetcher(`${stackApiV1BaseURL()}${path}`, {
        method: "POST",
        headers: stackClientHeaders(projectId, publishableKey, accessToken),
        body: JSON.stringify({ code }),
        signal: AbortSignal.timeout(10_000),
      }), { "cmux.auth.flow": "team_invitation_accept" });
    } catch {
      return { ok: false, failure: "unavailable" };
    }
    return interpretResponse(response);
  }

  return {
    async details(code, accessToken) {
      const result = await call("/team-invitations/accept/details", code, accessToken);
      if (!result.ok) return result;
      const body = result.value as { team_id?: unknown; team_display_name?: unknown } | null;
      if (typeof body?.team_id !== "string" || !body.team_id) return { ok: false, failure: "unavailable" };
      return {
        ok: true,
        value: {
          teamId: body.team_id,
          teamDisplayName: typeof body.team_display_name === "string" ? body.team_display_name : "",
        },
      };
    },
    async accept(code, accessToken) {
      const result = await call("/team-invitations/accept", code, accessToken);
      return result.ok ? { ok: true, value: null } : result;
    },
  };
}

function stackApiV1BaseURL(): string {
  const base = stackApiBaseURL();
  return /\/api\/v1$/u.test(base) ? base : `${base}/api/v1`;
}

function stackClientHeaders(projectId: string, publishableKey: string, accessToken: string): Record<string, string> {
  return {
    "content-type": "application/json",
    // Current Hexclave names plus the Stack aliases, as in app/lib/stack.ts.
    "x-hexclave-access-type": "client",
    "x-hexclave-project-id": projectId,
    "x-hexclave-publishable-client-key": publishableKey,
    "x-hexclave-access-token": accessToken,
    "x-hexclave-override-error-status": "true",
    "x-stack-access-type": "client",
    "x-stack-project-id": projectId,
    "x-stack-publishable-client-key": publishableKey,
    "x-stack-access-token": accessToken,
    "x-stack-override-error-status": "true",
  };
}

/** With override-error-status Stack answers 200 and names the real status and known error in headers. */
async function interpretResponse(response: Response): Promise<InvitationCodeResult<unknown>> {
  const actualStatus = Number(
    response.headers.get("x-hexclave-actual-status") ?? response.headers.get("x-stack-actual-status") ?? response.status,
  );
  let body: unknown = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  const knownError = response.headers.get("x-hexclave-known-error") ??
    response.headers.get("x-stack-known-error") ??
    (body && typeof body === "object" && typeof (body as { code?: unknown }).code === "string"
      ? (body as { code: string }).code
      : null);
  if (knownError === "TEAM_INVITATION_EMAIL_MISMATCH") return { ok: false, failure: "email_mismatch" };
  if (knownError?.startsWith("VERIFICATION_")) return { ok: false, failure: "invalid" };
  if (knownError || !Number.isFinite(actualStatus) || actualStatus < 200 || actualStatus >= 300) {
    return { ok: false, failure: "unavailable" };
  }
  return { ok: true, value: body };
}
