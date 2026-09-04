import type { StackServerApp } from "@stackframe/stack";
import type { NextRequest, NextResponse } from "next/server";

import {
  secureCookiesForRequest,
  setHexclaveSessionCookies,
  type HexclaveSessionTokens,
} from "./hexclave/session";

export type StackBrowserSessionTokens = HexclaveSessionTokens;

export type StackBrowserSessionHandoffAdapter = {
  establish(input: {
    readonly request: NextRequest;
    readonly response: NextResponse;
    readonly tokens: StackBrowserSessionTokens;
    readonly now: number;
  }): Promise<boolean>;
};

/**
 * Contains the one version-sensitive boundary between native handoff and
 * Stack's browser cookie store. The app argument is the real SDK type, so an
 * SDK token-store contract change fails typecheck here instead of being hidden
 * by a route-level cast. The cookie shape itself lives in
 * `hexclave/session.ts`, shared with the cmux-owned sign-in routes, and the
 * integration test pins the names and values @stackframe/stack 2.8.x reads.
 */
export function createStackBrowserSessionHandoffAdapter(
  app: StackServerApp<true>,
  projectId: string,
): StackBrowserSessionHandoffAdapter {
  return {
    establish: async ({ request, response, tokens, now }) => {
      const user = await app.getUser({ tokenStore: tokens });
      if (!user) return false;

      const validated = await user.currentSession.getTokens();
      if (!validated.refreshToken || !validated.accessToken) return false;

      setHexclaveSessionCookies(response, {
        projectId,
        secure: secureCookiesForRequest(request),
        tokens: {
          refreshToken: validated.refreshToken,
          accessToken: validated.accessToken,
        },
        now,
      });
      return true;
    },
  };
}
