import { ORPCError, os as baseOS } from "@orpc/server";

// The authenticated user is inferred once, at the resolution seam, from the
// exact getUser() call resolveStackUser makes below. Inferring at the root
// (rather than hand-rolling a structural type) keeps it byte-for-byte the Stack
// server-user type the billing helpers already accept, so procedures pass it on
// with no cast.
export type AuthedUser = NonNullable<Awaited<ReturnType<typeof resolveStackUser>>>;

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

async function resolveStackUser(request: Request) {
  // Dynamic import on purpose: app/lib/stack instantiates the Stack server app
  // and validates env at module load, so importing it lazily keeps the router
  // and its OpenAPI/type surface importable (and unit-testable) without a
  // configured Stack environment. This is the single Stack-coupling seam.
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
        return await app.getUser({
          tokenStore: { accessToken, refreshToken },
          or: "return-null",
        });
      } catch {
        return null;
      }
    }
  }

  try {
    return await app.getUser({
      tokenStore: request as unknown as { headers: Headers },
      or: "return-null",
    });
  } catch {
    return null;
  }
}
