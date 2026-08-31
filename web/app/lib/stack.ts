import { StackServerApp } from "@stackframe/stack";
import { env } from "../env";

// env.ts trims every runtimeEnv source, so consumers receive sanitized values
// regardless of whether zod validation is skipped.
const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
const publishableClientKey = env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
const secretServerKey = env.STACK_SECRET_SERVER_KEY;

let stackServerAppCache: StackServerApp<true> | null = null;
let nonRedirectingStackServerAppCache: StackServerApp<true> | null = null;

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
      accountSettings: "/dashboard/team",
    },
  });
  return stackServerAppCache;
}

// Native clients need a JSON response after revoking their exact token pair.
// Stack's normal Next.js redirect mode throws a redirect after sign-out, so
// keep a separate app instance whose session mutations never redirect.
export function getNonRedirectingStackServerApp(): StackServerApp<true> {
  if (!projectId || !publishableClientKey || !secretServerKey) {
    throw new Error("Stack Auth is not configured");
  }

  nonRedirectingStackServerAppCache ??= new StackServerApp({
    projectId,
    publishableClientKey,
    secretServerKey,
    tokenStore: "nextjs-cookie",
    redirectMethod: "none",
    urls: {
      afterSignIn: "/handler/after-sign-in",
      afterSignUp: "/handler/after-sign-in",
      accountSettings: "/dashboard/team",
    },
  });
  return nonRedirectingStackServerAppCache;
}

/**
 * Mark a server-owned Stack user's primary email as verified through the
 * server API.
 *
 * The SDK normally exposes this as `ServerUser.setPrimaryEmail(...,
 * { verified: true })`. This small fallback keeps the billing repair path
 * usable with an older SDK while keeping the secret server key entirely on
 * the server.
 */
export async function markStackUserEmailVerifiedViaApi(
  userId: string,
  email: string,
): Promise<void> {
  if (!projectId || !secretServerKey) {
    throw new Error("Stack Auth is not configured");
  }

  const configuredBaseURL =
    process.env.STACK_API_BASE_URL?.trim() ||
    process.env.NEXT_PUBLIC_SERVER_STACK_API_URL?.trim() ||
    process.env.NEXT_PUBLIC_STACK_API_URL?.trim() ||
    process.env.STACK_API_URL?.trim() ||
    "https://api.stack-auth.com";
  const baseURL = /\/api\/v1\/?$/u.test(configuredBaseURL)
    ? configuredBaseURL
    : `${configuredBaseURL.replace(/\/+$/, "")}/api/v1`;
  const response = await fetch(
    `${baseURL.replace(/\/+$/, "")}/users/${encodeURIComponent(userId)}`,
    {
      method: "PATCH",
      headers: {
        "content-type": "application/json",
        // Stack's current SDK uses the Hexclave-prefixed names; retain the
        // Stack aliases for older project API versions during the migration.
        "x-hexclave-access-type": "server",
        "x-hexclave-project-id": projectId,
        "x-hexclave-secret-server-key": secretServerKey,
        "x-hexclave-override-error-status": "true",
        "x-stack-access-type": "server",
        "x-stack-project-id": projectId,
        "x-stack-secret-server-key": secretServerKey,
        "x-stack-override-error-status": "true",
      },
      body: JSON.stringify({
        primary_email: email,
        primary_email_verified: true,
        primary_email_auth_enabled: true,
      }),
      signal: AbortSignal.timeout(10_000),
    },
  );
  if (!response.ok) {
    // Do not include response bodies: Stack can echo account data or provider
    // details, and this helper is called from webhook/recovery code paths.
    throw new Error("Stack Auth email verification update failed");
  }
}

export const stackServerApp = isStackConfigured() ? getStackServerApp() : null;
