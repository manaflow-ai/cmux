/**
 * Where the Stack SDK keeps the browser refresh token. Current SDKs write
 * `hexclave-refresh-<project>--<suffix>` (with a `__Host-` prefix on secure
 * origins); older sessions still carry `stack-refresh-<project>` or the bare
 * `stack-refresh`. Mirrors `_getRefreshTokenCookieNamePatterns` in
 * `@stackframe/js`, so the edge gate and the session key agree with the SDK.
 */
export type CookieLike = { readonly name: string; readonly value: string };

export function stackRefreshCookiePatterns(projectId: string): {
  readonly exact: readonly string[];
  readonly prefixes: readonly string[];
} {
  const current = `hexclave-refresh-${projectId}`;
  const legacy = `stack-refresh-${projectId}`;
  return {
    exact: [legacy, "stack-refresh"],
    prefixes: [
      `${current}--`,
      `__Host-${current}--`,
      `${legacy}--`,
      `__Host-${legacy}--`,
    ],
  };
}

/** The refresh cookies present for this project, current names first. */
export function stackRefreshCookies(
  cookies: Iterable<CookieLike>,
  projectId: string,
): CookieLike[] {
  const { exact, prefixes } = stackRefreshCookiePatterns(projectId);
  const structured: CookieLike[] = [];
  const legacy: CookieLike[] = [];
  for (const cookie of cookies) {
    if (!cookie.value) continue;
    if (prefixes.some((prefix) => cookie.name.startsWith(prefix))) {
      structured.push(cookie);
    } else if (exact.includes(cookie.name)) {
      legacy.push(cookie);
    }
  }
  return [...structured, ...legacy];
}

export function hasStackRefreshCookie(
  cookies: Iterable<CookieLike>,
  projectId: string,
): boolean {
  return stackRefreshCookies(cookies, projectId).length > 0;
}
