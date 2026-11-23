import { env } from "../../../env";
import { createDbHandoffCodeStore } from "../../../lib/handoff-codes";
import { stackServerApp } from "../../../lib/stack";
import { makeConsoleSignInTokenHandler } from "../../../../services/auth/consoleSignIn";

/**
 * POST /handler/console-sign-in/token: the console server redeems a one-time
 * code for a fresh session (services/auth/consoleSignIn.ts). Tokens appear only
 * in this response body.
 */
export const POST = makeConsoleSignInTokenHandler({
  store: stackServerApp ? createDbHandoffCodeStore() : null,
  secrets: {
    production: env.CMUX_CONSOLE_SIGN_IN_SECRET,
    staging: env.CMUX_CONSOLE_STAGING_SIGN_IN_SECRET,
  },
  mintSession: async (userId, expiresInMillis) => {
    if (!stackServerApp) return null;
    const user = await stackServerApp.getUser(userId);
    if (!user || user.isAnonymous) return null;
    const session = await user.createSession({ expiresInMillis });
    const tokens = await session.getTokens();
    return tokens.accessToken && tokens.refreshToken ? { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken } : null;
  },
});
