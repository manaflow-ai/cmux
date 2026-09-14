import { cache } from "react";
import { cacheLife } from "next/cache";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";

import {
  isSubrouterAuthorizationError,
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline,
} from "../../services/vms/auth";
import {
  DASHBOARD_RETURN_PATH_HEADER,
  normalizeDashboardReturnPath,
} from "./dashboard-return-path";
import { isStackConfigured } from "./stack";
import { stackRefreshCookies } from "./stack-session-cookies";
import { localizedVaultPath, vaultSignInHref } from "./vault-auth";

/**
 * The narrow, serializable view of the signed-in browser user that dashboard
 * server components share. Only this shape may leave the private cache, so
 * tokens and SDK objects never reach the client.
 */
export type DashboardSessionUser = {
  readonly id: string;
  readonly displayName: string | null;
  readonly primaryEmail: string | null;
  readonly primaryEmailVerified: boolean;
  readonly profileImageUrl: string | null;
  readonly selectedTeamId: string | null;
  readonly isAnonymous: false;
};

export class DashboardSessionMissingError extends Error {
  override readonly name = "DashboardSessionMissingError";
}

export class DashboardSessionUnavailableError extends Error {
  override readonly name = "DashboardSessionUnavailableError";
}

/**
 * Length of time the browser may reuse a resolved session between client
 * navigations. API routes still verify every request, so this only bounds
 * how long the dashboard chrome can lag a sign-out made elsewhere.
 */
export const DASHBOARD_SESSION_STALE_SECONDS = 300;

/**
 * Identify the browser session without reading token contents. Only the
 * refresh cookies change across sign-in and sign-out, so their digest is
 * enough to key the private cache and never cache one user's session for
 * another. Every Stack cookie name variant is included.
 */
export async function dashboardSessionKey(): Promise<string> {
  const store = await cookies();
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
  const refreshCookies = projectId
    ? stackRefreshCookies(store.getAll(), projectId)
    : [];
  if (refreshCookies.length === 0) return "anonymous";
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(
      refreshCookies.map((cookie) => `${cookie.name}=${cookie.value}`).join("\n"),
    ),
  );
  return Array.from(new Uint8Array(digest).slice(0, 12), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

const INTL_LOCALE_HEADER = "x-next-intl-locale";

/**
 * Resolve the browser user once per server render and, through the private
 * cache, once per browser session per stale window. Only a resolved user is
 * cached: a rejected cookie redirects to sign-in from inside the cached
 * scope, which the framework recognizes, and an outage throws.
 */
export const readDashboardSessionUser = cache(
  async (): Promise<DashboardSessionUser> => {
    if (!isStackConfigured()) throw new DashboardSessionMissingError("Stack Auth is not configured");
    const sessionKey = await dashboardSessionKey();
    if (sessionKey === "anonymous") {
      throw new DashboardSessionMissingError("No dashboard session cookie");
    }
    return readCachedDashboardSessionUser(sessionKey);
  },
);

async function readCachedDashboardSessionUser(
  sessionKey: string,
): Promise<DashboardSessionUser> {
  "use cache: private";
  cacheLife({ stale: DASHBOARD_SESSION_STALE_SECONDS });
  // The key is part of the cache identity even though the body reads the
  // request directly. Keep the reference so the argument is not elided.
  void sessionKey;

  let user: Awaited<ReturnType<typeof verifyBrowserSessionRequest>>;
  try {
    const requestHeaders = await headers();
    user = await withSubrouterAuthorizationDeadline((signal) =>
      verifyBrowserSessionRequest(
        new Request("https://cmux.com/dashboard", {
          headers: Object.fromEntries(requestHeaders.entries()),
        }),
        signal,
      )
    );
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      console.error("Dashboard Stack authorization unavailable", {
        errorType: error instanceof Error ? error.name : typeof error,
      });
      throw new DashboardSessionUnavailableError(
        "Dashboard Stack authorization unavailable",
        { cause: error },
      );
    }
    throw error;
  }
  if (!user) {
    // The destination and locale come from request headers set by the
    // middleware, so they stay out of the cache key.
    const requestHeaders = await headers();
    redirect(vaultSignInHref(localizedVaultPath(
      requestHeaders.get(INTL_LOCALE_HEADER) ?? "en",
      normalizeDashboardReturnPath(
        requestHeaders.get(DASHBOARD_RETURN_PATH_HEADER),
        "/dashboard",
      ),
    )));
  }
  return {
    id: user.id,
    displayName: user.displayName ?? null,
    primaryEmail: user.primaryEmail ?? null,
    primaryEmailVerified: user.primaryEmailVerified === true,
    profileImageUrl: user.profileImageUrl ?? null,
    selectedTeamId: user.selectedTeam?.id ?? null,
    isAnonymous: false,
  };
}
