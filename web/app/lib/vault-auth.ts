import { SIGN_IN_PATH } from "./auth-paths";

export function vaultSignInHref(returnPath: string): string {
  const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.com");
  afterSignIn.searchParams.set("after_auth_return_to", returnPath);
  const signIn = new URL(SIGN_IN_PATH, "https://cmux.com");
  signIn.searchParams.set(
    "after_auth_return_to",
    `${afterSignIn.pathname}${afterSignIn.search}`,
  );
  return `${signIn.pathname}${signIn.search}`;
}

/**
 * The sign-in page's account chooser, coming back to `returnPath` as
 * whichever account is picked. Saved accounts switch in one click; nothing is
 * signed out first.
 */
export function vaultSwitchAccountHref(returnPath: string): string {
  const url = new URL(vaultSignInHref(returnPath), "https://cmux.com");
  url.searchParams.set("prompt", "select_account");
  return `${url.pathname}${url.search}`;
}

export function localizedVaultPath(locale: string, path: string): string {
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return `/${locale}${suffix}`;
}
