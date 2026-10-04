"use client";

import { StackClientApp } from "@hexclave/next";
import { reportHexclaveSetupOverlays } from "./hexclave-overlay-guard";

const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
const publishableClientKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;

// The publishable key is optional: the production project does not require
// one, and Stack rejects a revoked key, so an unset key is sent as no key.
export const stackClientApp = projectId
  ? new StackClientApp({
      projectId,
      ...(publishableClientKey ? { publishableClientKey } : {}),
      tokenStore: "cookie",
      urls: {
        afterSignIn: "/handler/after-sign-in",
        afterSignUp: "/handler/after-sign-in",
        accountSettings: "/dashboard/settings",
      },
    })
  : null;

if (stackClientApp && typeof window !== "undefined") {
  reportHexclaveSetupOverlays();
}
