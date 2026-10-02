/**
 * Request-scope stand-ins for dashboard server components. The session key
 * is derived from the Stack refresh cookie, so tests that want a signed-in
 * request set the cookie and the matching project id.
 */
export const TEST_STACK_PROJECT_ID = "123e4567-e89b-12d3-a456-426614174000";
export const TEST_STACK_REFRESH_COOKIE = `stack-refresh-${TEST_STACK_PROJECT_ID}`;

export function nextHeadersMock(state: {
  readonly headers?: () => Headers;
  readonly refreshToken?: () => string | null;
}) {
  return {
    headers: async () => state.headers?.() ?? new Headers(),
    cookies: async () => {
      const value = state.refreshToken?.() ?? null;
      const all = value ? [{ name: TEST_STACK_REFRESH_COOKIE, value }] : [];
      return {
        get: (name: string) => all.find((cookie) => cookie.name === name),
        getAll: () => all,
      };
    },
  };
}
