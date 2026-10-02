// Public URLs of cmux's sign-in and sign-up pages.
//
// `/sign-in` and `/sign-up` are canonical. The proxy rewrites them onto the
// handler pages that render the forms (`/handler/sign-in`, `/handler/sign-up`),
// and every alias, including those handler paths, 308s to the canonical URL
// with its query intact. Redirects run on the incoming URL before the proxy,
// so the rewrite never meets them and cannot loop. Every other `/handler/*`
// route (OAuth and magic-link callbacks, verification, password reset) is
// left alone.

export const SIGN_IN_PATH = "/sign-in";
export const SIGN_UP_PATH = "/sign-up";

export type AuthPage = "sign-in" | "sign-up";

/** The handler page each canonical path renders. */
export const AUTH_PAGE_HANDLERS: ReadonlyMap<string, AuthPage> = new Map<string, AuthPage>([
  [SIGN_IN_PATH, "sign-in"],
  [SIGN_UP_PATH, "sign-up"],
]);

/** Paths that permanently redirect to a canonical auth page. */
export const AUTH_PATH_ALIASES: Record<AuthPage, readonly string[]> = {
  "sign-in": ["/handler/sign-in", "/login", "/log-in", "/signin"],
  "sign-up": ["/handler/sign-up", "/signup", "/register", "/create-account"],
};

const CANONICAL: Record<AuthPage, string> = {
  "sign-in": SIGN_IN_PATH,
  "sign-up": SIGN_UP_PATH,
};

/** next.config redirects for every alias. Next keeps the query string. */
export function authPathRedirects(): { source: string; destination: string; permanent: true }[] {
  return (Object.keys(AUTH_PATH_ALIASES) as AuthPage[]).flatMap((page) =>
    AUTH_PATH_ALIASES[page].map((source) => ({ source, destination: CANONICAL[page], permanent: true as const })),
  );
}

/** True for a URL path that shows the sign-in page, canonical or legacy. */
export function isSignInPath(pathname: string): boolean {
  return pathname === SIGN_IN_PATH || pathname === "/handler/sign-in";
}

/** The canonical URL a crawler should index for an auth page. */
export function canonicalAuthUrl(page: AuthPage): string {
  return `https://cmux.com${CANONICAL[page]}`;
}

/**
 * Hexclave page URLs for every app instance, so the SDK's own redirects and
 * links (`redirectToSignIn`, `urls.signUp`) land on the canonical pages.
 */
export const HEXCLAVE_AUTH_PAGE_URLS = {
  signIn: { type: "custom", url: SIGN_IN_PATH, version: 0 },
  signUp: { type: "custom", url: SIGN_UP_PATH, version: 0 },
} as const;
