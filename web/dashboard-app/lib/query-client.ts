import { MutationCache, QueryCache, QueryClient } from "@tanstack/react-query";
import { dashboardBasepath } from "./basepath";
import { signInHref } from "./session";

/** Every dashboard API reports a missing or revoked session as HTTP 401. */
export function isUnauthorizedError(error: unknown): boolean {
  return typeof error === "object" && error !== null &&
    (error as { status?: unknown }).status === 401;
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
        retry: (failureCount, error) => !isUnauthorizedError(error) && failureCount < 3,
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
