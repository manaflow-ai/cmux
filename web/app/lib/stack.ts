import { StackServerApp } from "@stackframe/stack";
import { env } from "../env";

// `.trim()` at the consumption site too: `env` can skip zod validation in
// preview builds (VERCEL_ENV === "preview"), which would pass unprocessed
// values through. A trailing newline in a Vercel env var has tripped Stack
// Auth's UUID parser ("Invalid project ID: <uuid>\n") during builds.
export const stackServerApp = new StackServerApp({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID.trim(),
  publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY.trim(),
  secretServerKey: env.STACK_SECRET_SERVER_KEY.trim(),
  tokenStore: "nextjs-cookie",
  urls: {
    afterSignIn: "/handler/after-sign-in",
    afterSignUp: "/handler/after-sign-in",
  },
});
