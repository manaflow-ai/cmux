import { StackServerApp } from "@stackframe/stack";
import { env } from "../env";

// env.ts trims every runtimeEnv source, so consumers receive sanitized values
// regardless of whether zod validation is skipped.
const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
const publishableClientKey = env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
const secretServerKey = env.STACK_SECRET_SERVER_KEY;

let stackServerAppCache: StackServerApp<true> | null = null;

export function isStackConfigured(): boolean {
  return Boolean(projectId && publishableClientKey && secretServerKey);
}

export function getStackServerApp(): StackServerApp<true> {
  if (!projectId || !publishableClientKey || !secretServerKey) {
    throw new Error("Stack Auth is not configured");
  }

  stackServerAppCache ??= new StackServerApp({
    projectId,
    publishableClientKey,
    secretServerKey,
    tokenStore: "nextjs-cookie",
    urls: {
      afterSignIn: "/handler/after-sign-in",
      afterSignUp: "/handler/after-sign-in",
    },
  });
  return stackServerAppCache;
}

export const stackServerApp = isStackConfigured() ? getStackServerApp() : null;
