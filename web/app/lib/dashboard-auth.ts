import { headers } from "next/headers";
import { redirect, unstable_rethrow } from "next/navigation";

import {
  type DashboardSessionUser,
  DashboardSessionMissingError,
  DashboardSessionUnavailableError,
  readDashboardSessionUser,
} from "./dashboard-session";
import { isStackConfigured } from "./stack";
import {
  DASHBOARD_RETURN_PATH_HEADER,
  normalizeDashboardReturnPath,
} from "./dashboard-return-path";
import { localizedVaultPath, vaultSignInHref } from "./vault-auth";

export type { DashboardSessionUser } from "./dashboard-session";

export class DashboardAuthorizationUnavailableError extends Error {
  override readonly name = "DashboardAuthorizationUnavailableError";
}

export type DashboardSection =
  | { readonly kind: "user"; readonly user: DashboardSessionUser }
  | { readonly kind: "unavailable" };

/**
 * Read the dashboard destination set by middleware. The value is restricted
 * to dashboard-local paths before it reaches the sign-in redirect.
 */
export async function dashboardReturnPath(
  fallback = "/dashboard",
): Promise<string> {
  const requestHeaders = await headers();
  return normalizeDashboardReturnPath(
    requestHeaders.get(DASHBOARD_RETURN_PATH_HEADER),
    fallback,
  );
}

/**
 * Resolve the signed-in user for a private dashboard section, redirecting a
 * missing session to sign-in. Call it inside the section's own Suspense
 * boundary so the static shell above it never waits on Stack.
 */
export async function requireDashboardUser(
  locale: string,
  returnPath: string = "/dashboard",
): Promise<DashboardSessionUser> {
  const section = await loadDashboardSection(locale, returnPath);
  if (section.kind === "unavailable") {
    throw new DashboardAuthorizationUnavailableError(
      "Dashboard Stack authorization unavailable",
    );
  }
  return section.user;
}

/**
 * Like `requireDashboardUser`, but reports a Stack outage as a value so a
 * section can render recovery UI in place instead of failing the route.
 */
export async function loadDashboardSection(
  locale: string,
  returnPath: string = "/dashboard",
): Promise<DashboardSection> {
  if (!isStackConfigured()) redirect("/");
  try {
    return { kind: "user", user: await readDashboardSessionUser() };
  } catch (error) {
    // A framework redirect from inside the cached scope must propagate.
    unstable_rethrow(error);
    if (error instanceof DashboardSessionMissingError) {
      redirect(dashboardAuthorizationSignInHref(locale, returnPath));
    }
    // Anything else crossed the cache boundary, where prototypes are not
    // preserved, or is a Stack outage; both render recovery UI in place.
    if (!(error instanceof DashboardSessionUnavailableError)) {
      console.error("Dashboard session read failed", {
        errorType: error instanceof Error ? error.name : typeof error,
      });
    }
    return { kind: "unavailable" };
  }
}

/** The signed-in user for chrome that must render for signed-out visitors too. */
export async function optionalDashboardUser(): Promise<DashboardSessionUser | null> {
  if (!isStackConfigured()) return null;
  try {
    return await readDashboardSessionUser();
  } catch (error) {
    unstable_rethrow(error);
    return null;
  }
}

/** Render a standalone recovery view without mounting the private shell. */
export function dashboardAuthorizationSignInHref(
  locale: string,
  returnPath: string,
): string {
  return vaultSignInHref(localizedVaultPath(
    locale,
    normalizeDashboardReturnPath(returnPath),
  ));
}
