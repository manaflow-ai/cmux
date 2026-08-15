export function vaultSignInHref(returnPath: string): string {
  const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.com");
  afterSignIn.searchParams.set("after_auth_return_to", returnPath);
  const signIn = new URL("/handler/sign-in", "https://cmux.com");
  signIn.searchParams.set(
    "after_auth_return_to",
    `${afterSignIn.pathname}${afterSignIn.search}`,
  );
  return `${signIn.pathname}${signIn.search}`;
}

export function localizedVaultPath(locale: string, path: string): string {
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return `/${locale}${suffix}`;
}
