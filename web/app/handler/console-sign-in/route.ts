import { checkRateLimit } from "@vercel/firewall";
import { env } from "../../env";
import { createDbHandoffCodeStore } from "../../lib/handoff-codes";
import { requestOrigin } from "../../lib/request-origin";
import { stackServerApp } from "../../lib/stack";
import { consoleSignInRateLimitId, makeConsoleSignInAuthorizeHandler } from "../../../services/auth/consoleSignIn";

/** GET /handler/console-sign-in: issues a one-time code to the Cloud console (services/auth/consoleSignIn.ts). */
export const GET = makeConsoleSignInAuthorizeHandler({
  store: stackServerApp ? createDbHandoffCodeStore() : null,
  secrets: {
    production: env.CMUX_CONSOLE_SIGN_IN_SECRET,
    staging: env.CMUX_CONSOLE_STAGING_SIGN_IN_SECRET,
  },
  currentUser: async () => {
    if (!stackServerApp) return null;
    const user = await stackServerApp.getUser({ or: "return-null" });
    return user ? { id: user.id, isAnonymous: user.isAnonymous } : null;
  },
  origin: (request) => requestOrigin(request),
  checkRateLimit,
  // Deployed (Vercel): its own limiter only, and the route refuses without it. Locally the feedback one is enough.
  rateLimitId: consoleSignInRateLimitId(env, process.env.VERCEL === "1"),
});
