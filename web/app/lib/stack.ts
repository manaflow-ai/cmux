import { StackServerApp } from "@stackframe/stack";
import { env } from "../env";

// env.ts now trims every runtimeEnv source, so consumers receive sanitized
// values regardless of whether zod validation is skipped. No point-of-use
// trim needed here.
const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
const publishableClientKey = env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
const secretServerKey = env.STACK_SECRET_SERVER_KEY;

export const stackServerApp =
  projectId && publishableClientKey && secretServerKey
    ? new StackServerApp({
        projectId,
        publishableClientKey,
        secretServerKey,
        tokenStore: "nextjs-cookie",
        urls: {
          afterSignIn: "/handler/after-sign-in",
          afterSignUp: "/handler/after-sign-in",
        },
      })
    : null;
