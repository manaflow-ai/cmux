"use client";

import { StackClientApp } from "@stackframe/stack";

const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
const publishableClientKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;

export const stackClientApp = projectId && publishableClientKey
  ? new StackClientApp({
      projectId,
      publishableClientKey,
      tokenStore: "cookie",
      urls: {
        afterSignIn: "/handler/after-sign-in",
        afterSignUp: "/handler/after-sign-in",
        accountSettings: "/dashboard/team",
      },
    })
  : null;
