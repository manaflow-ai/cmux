import { ORPCError, os as baseOS } from "@orpc/server";

// Structural shape of the authenticated Stack user the procedures rely on.
// Kept local (no Stack/Next import) so the router stays portable to Vite/Hono.
export type AuthedUser = {
  readonly id?: string;
  readonly primaryEmail?: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  listProducts?: (...args: unknown[]) => Promise<unknown>;
  update?: (...args: unknown[]) => Promise<unknown>;
};

export type ORPCContext = {
  request: Request;
  user: AuthedUser | null;
};

export const os = baseOS.$context<ORPCContext>();

export const requireAuth = os.middleware(async ({ context, next }) => {
  if (!context.user) {
    throw new ORPCError("UNAUTHORIZED");
  }
  return next({
    context: {
      ...context,
      user: context.user,
    },
  });
});

export async function createORPCContext(request: Request): Promise<ORPCContext> {
  const user = await resolveStackUser(request);
  return { request, user };
}

async function resolveStackUser(request: Request): Promise<AuthedUser | null> {
  const { getStackServerApp, isStackConfigured } = await import("../../app/lib/stack");
  if (!isStackConfigured()) return null;

  const authHeader = request.headers.get("authorization") ?? request.headers.get("Authorization");
  const refreshToken = request.headers.get("x-stack-refresh-token") ?? request.headers.get("X-Stack-Refresh-Token");
  const bearerMatch = authHeader?.match(/^Bearer\s+(.+)$/i);
  const app = getStackServerApp();

  if (bearerMatch && refreshToken) {
    const accessToken = bearerMatch[1]?.trim();
    if (accessToken) {
      try {
        return (await app.getUser({
          tokenStore: { accessToken, refreshToken },
          or: "return-null",
        })) as unknown as AuthedUser | null;
      } catch {
        return null;
      }
    }
  }

  try {
    return (await app.getUser({
      tokenStore: request as unknown as { headers: Headers },
      or: "return-null",
    })) as unknown as AuthedUser | null;
  } catch {
    return null;
  }
}
