import { StackServerApp } from "@stackframe/stack";
import { env } from "../env";

// env.ts now trims every runtimeEnv source, so consumers receive sanitized
// values regardless of whether zod validation is skipped. No point-of-use
// trim needed here.
export const stackServerApp = new StackServerApp({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
  secretServerKey: env.STACK_SECRET_SERVER_KEY,
  tokenStore: "nextjs-cookie",
  urls: {
    afterSignIn: "/handler/after-sign-in",
    afterSignUp: "/handler/after-sign-in",
  },
});
