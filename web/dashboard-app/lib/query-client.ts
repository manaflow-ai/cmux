import { MutationCache, QueryCache, QueryClient } from "@tanstack/react-query";
import { dashboardBasepath } from "./basepath";
import { dashboardRefusal } from "./refusal";
import { signInHref } from "./session";

/** Every dashboard API reports a missing or revoked session as HTTP 401. */
export function isUnauthorizedError(error: unknown): boolean {
  return typeof error === "object" && error !== null &&
    (error as { status?: unknown }).status === 401;
}

/**
 * Only failures that can pass on a retry: network errors, undeclared server
 * errors, and declared 5xx refusals. A declared 4xx refusal (forbidden, not
 * found, a disabled feature) answers the same way every time.
 */
export function isTransientError(error: unknown): boolean {
  const refusal = dashboardRefusal(error);
  if (refusal) return refusal.status >= 500;
  return !isUnauthorizedError(error);
}

/** Delay before the single retry of a transient failure. */
export const DASHBOARD_RETRY_DELAY_MS = 1000;

/**
 * One retry for a transient failure, none for a declared 4xx. A second
 * attempt rides out a blip; more attempts only keep an outage behind a
 * skeleton, so the page shows its error (with Try again) within ~2 s.
 */
export function shouldRetryQuery(failureCount: number, error: unknown): boolean {
  return isTransientError(error) && failureCount < 1;
}

/**
 * The SPA's query client. A 401 from any query or mutation means the session
 * ended after the shell loaded (sign-out elsewhere, revoked session, expired
 * refresh token), so it goes to sign-in instead of rendering an error card
 * next to a stale identity. 401s are never retried.
 */
export function createDashboardQueryClient(onUnauthorized: () => void): QueryClient {
  const handle = (error: unknown) => {
    if (isUnauthorizedError(error)) onUnauthorized();
  };
  return new QueryClient({
    queryCache: new QueryCache({ onError: handle }),
    mutationCache: new MutationCache({ onError: handle }),
    defaultOptions: {
      queries: {
        staleTime: 30_000,
        refetchOnWindowFocus: true,
        retry: shouldRetryQuery,
        retryDelay: DASHBOARD_RETRY_DELAY_MS,
      },
    },
  });
}

/** Sends the browser to sign-in once, returning to the current dashboard URL. */
export function createSignInRedirect(locale: string, win: Window = window): () => void {
  let redirected = false;
  return () => {
    if (redirected) return;
    redirected = true;
    const { pathname, search } = win.location;
    const basepath = dashboardBasepath(pathname);
    const path = basepath && pathname.startsWith(basepath) ? pathname.slice(basepath.length) || "/" : pathname;
    win.location.replace(signInHref(locale, `${path}${search}`));
  };
}
