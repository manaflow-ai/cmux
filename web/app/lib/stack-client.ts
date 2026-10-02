"use client";

import { StackClientApp } from "@hexclave/next";
import { reportHexclaveSetupOverlays } from "./hexclave-overlay-guard";
import { HEXCLAVE_AUTH_PAGE_URLS } from "./auth-paths";

const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
const publishableClientKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;

export const stackClientApp = projectId && publishableClientKey
  ? new StackClientApp({
      projectId,
      publishableClientKey,
      tokenStore: "cookie",
      urls: {
        ...HEXCLAVE_AUTH_PAGE_URLS,
        afterSignIn: "/handler/after-sign-in",
        afterSignUp: "/handler/after-sign-in",
        accountSettings: "/dashboard/settings",
      },
    })
  : null;

if (stackClientApp && typeof window !== "undefined") {
  reportHexclaveSetupOverlays();
}
