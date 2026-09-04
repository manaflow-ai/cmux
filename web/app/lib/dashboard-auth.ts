import { cache } from "react";
import { headers } from "next/headers";
import { redirect } from "next/navigation";

import {
  isSubrouterAuthorizationError,
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline,
} from "../../services/vms/auth";
import { isStackConfigured } from "./stack";
import {
  DASHBOARD_RETURN_PATH_HEADER,
  normalizeDashboardReturnPath,
} from "./dashboard-return-path";
import { localizedVaultPath, vaultSignInHref } from "./vault-auth";

export class DashboardAuthorizationUnavailableError extends Error {
  override readonly name = "DashboardAuthorizationUnavailableError";
}

type DashboardAuthState =
  | { readonly kind: "unconfigured" }
  | { readonly kind: "missing" }
  | {
    readonly kind: "authenticated";
    readonly user: NonNullable<Awaited<ReturnType<typeof verifyBrowserSessionRequest>>>;
  }
  | { readonly kind: "unavailable" };

/**
 * Resolve the browser session once per server render. The Stack call is
 * bounded by the same authorization deadline used by API routes, so a slow
 * auth provider cannot hold the dashboard shell open forever.
 */
const readDashboardAuth = cache(async (): Promise<DashboardAuthState> => {
  if (!isStackConfigured()) return { kind: "unconfigured" };

  try {
    const requestHeaders = await headers();
    const user = await withSubrouterAuthorizationDeadline((signal) =>
      verifyBrowserSessionRequest(
        new Request("https://cmux.com/dashboard", {
          headers: Object.fromEntries(requestHeaders.entries()),
        }),
        signal,
      )
    );
    return user ? { kind: "authenticated", user } : { kind: "missing" };
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      console.error("Dashboard Stack authorization unavailable", {
        errorType: error instanceof Error ? error.name : typeof error,
      });
      return { kind: "unavailable" };
    }
    throw error;
  }
});

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

export async function requireDashboardUser(
  locale: string,
  returnPath: string = "/dashboard",
) {
  const state = await readDashboardAuth();
  if (state.kind === "unconfigured") redirect("/");
  if (state.kind === "unavailable") {
    throw new DashboardAuthorizationUnavailableError(
      "Dashboard Stack authorization unavailable",
    );
  }
  if (state.kind === "missing") {
    redirect(vaultSignInHref(localizedVaultPath(
      locale,
      normalizeDashboardReturnPath(returnPath),
    )));
  }
  return state.user;
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
