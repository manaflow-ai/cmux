import { env } from "@/app/env";
import { readJoinViewer, type JoinViewer } from "@/app/lib/dashboard-auth";
import { getStackServerApp } from "@/app/lib/stack";
import { vaultSignInHref } from "@/app/lib/vault-auth";
import {
  isSubrouterAuthorizationError,
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";
import { browserMutationOriginAllowed } from "@/services/vms/routeHelpers";
import { withStackAuthSpan } from "@/services/auth/stackTelemetry";
import { LINK_PAGE_PATH, type LinkDeps, type SessionResult, json, personalTeamId, platformBaseUrl, signInRequired } from "./link";
import { loadAuthorListings } from "./registry";

/** Sign-in that comes back to the link page. */
export const LINK_SIGN_IN_URL = vaultSignInHref(LINK_PAGE_PATH);

/** Who is looking at the link page: signed in, signed out, or Stack could not say (throttled or down). */
export function readLinkViewer(): Promise<JoinViewer> {
  return readJoinViewer();
}

/**
 * The browser's cmux session for a link route: its Stack access token (refreshed when needed) and
 * the person's own team. A mutation must come from cmux.com itself, since it rides on cookies.
 */
export async function resolveLinkSession(request: Request): Promise<SessionResult> {
  if (!["GET", "HEAD"].includes(request.method) && !browserMutationOriginAllowed(request)) {
    return { ok: false, response: json({ code: "extension.forbidden", message: "Link a repo from cmux.com." }, 403) };
  }
  const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
  if (!projectId) return { ok: false, response: signInRequired(LINK_SIGN_IN_URL) };
  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifyBrowserSessionRequest(request, signal);
      if (!user) return { ok: false, response: signInRequired(LINK_SIGN_IN_URL) };
      const tokenStore = { headers: { get: (name: string): string | null => request.headers.get(name) } };
      const tokens = await withStackAuthSpan("get_auth_json", () => getStackServerApp().getAuthJson({ tokenStore }), {
        "cmux.auth.flow": "extensions_link",
      });
      if (!tokens?.accessToken) return { ok: false, response: signInRequired(LINK_SIGN_IN_URL) };
      return { ok: true, session: { accessToken: tokens.accessToken, team: personalTeamId(projectId, user.id) } };
    });
  } catch (error) {
    if (!isSubrouterAuthorizationError(error)) throw error;
    console.error("extensions.link_session_unavailable", { errorType: error.name });
    return {
      ok: false,
      response: json({ code: "extension.unavailable", message: "cmux sign-in could not be checked. Try again in a minute." }, 503),
    };
  }
}

/** The live wiring the route handlers use. */
export function linkDeps(): LinkDeps {
  return {
    session: resolveLinkSession,
    fetch: (input, init) => fetch(input, init),
    baseUrl: platformBaseUrl(),
    authorListings: (owner) => loadAuthorListings(owner),
  };
}
