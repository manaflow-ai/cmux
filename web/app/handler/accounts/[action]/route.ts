import { env } from "../../../env";
import { createUncachedStackServerApp, isStackConfigured, stackServerApp } from "../../../lib/stack";
import { makeAccountsHandler } from "./handler";

// A refresh token alone is enough: the empty access token makes the service
// issue a fresh one, which is also how a revoked or expired session shows up
// (no user comes back). Each check uses a new app, so no cached access token
// can stand in for that refresh.
const withRefreshToken = (refreshToken: string) => ({ accessToken: "", refreshToken });

export const POST = makeAccountsHandler({
  secret: isStackConfigured() ? env.STACK_SECRET_SERVER_KEY ?? null : null,
  currentSession: async (request) => {
    const user = await stackServerApp?.getUser({ tokenStore: request });
    if (!user) return null;
    const { refreshToken } = await user.currentSession.getTokens();
    return refreshToken ? { id: user.id, refreshToken } : null;
  },
  lookup: async (refreshToken) => {
    const user = await createUncachedStackServerApp().getUser({ tokenStore: withRefreshToken(refreshToken) });
    if (!user) return { status: "invalid" };
    const tokens = await user.currentSession.getTokens();
    if (!tokens.accessToken || !tokens.refreshToken) return { status: "invalid" };
    return { status: "valid", id: user.id, tokens: { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken } };
  },
  revoke: async (refreshToken) => {
    await createUncachedStackServerApp().signOut({ tokenStore: withRefreshToken(refreshToken) });
  },
});
