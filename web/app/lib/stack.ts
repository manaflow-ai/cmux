import { StackClientApp, StackServerApp } from "@stackframe/stack";
import { env, STACK_SECRET_SERVER_KEY_PLACEHOLDERS } from "../env";

// env.ts trims every runtimeEnv source, so consumers receive sanitized values
// regardless of whether zod validation is skipped.
const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
const publishableClientKey = env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
const secretServerKey = env.STACK_SECRET_SERVER_KEY;

let stackServerAppCache: StackServerApp<true> | null = null;
type StackHandlerApp = StackClientApp<true> | StackServerApp<true>;
let stackHandlerAppCache: StackHandlerApp | null = null;

export function isStackConfigured(): boolean {
  return Boolean(projectId && publishableClientKey && hasRealSecretServerKey());
}

export function isStackHandlerConfigured(): boolean {
  return Boolean(projectId && publishableClientKey);
}

export function getStackServerApp(): StackServerApp<true> {
  if (!projectId || !publishableClientKey || !hasRealSecretServerKey()) {
    throw new Error("Stack Auth is not configured");
  }

  stackServerAppCache ??= new StackServerApp({
    ...stackAppOptions(),
    secretServerKey,
  });
  return stackServerAppCache;
}

export function getStackHandlerApp(): StackHandlerApp {
  if (!projectId || !publishableClientKey) {
    throw new Error("Stack Auth handler is not configured");
  }
  if (hasRealSecretServerKey()) return getStackServerApp();

  stackHandlerAppCache ??= new StackClientApp(stackAppOptions());
  return stackHandlerAppCache;
}

export const stackServerApp = isStackConfigured() ? getStackServerApp() : null;
export const stackHandlerApp = isStackHandlerConfigured() ? getStackHandlerApp() : null;

function hasRealSecretServerKey(): boolean {
  return Boolean(
    secretServerKey && !STACK_SECRET_SERVER_KEY_PLACEHOLDERS.has(secretServerKey)
  );
}

function stackAppOptions() {
  return {
    projectId: projectId!,
    publishableClientKey: publishableClientKey!,
    tokenStore: "nextjs-cookie" as const,
    noAutomaticPrefetch: true,
    urls: {
      afterSignIn: "/handler/after-sign-in",
      afterSignUp: "/handler/after-sign-in",
    },
  };
}
