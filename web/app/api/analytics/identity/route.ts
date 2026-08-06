import { NextResponse } from "next/server";

import { getStackServerApp, isStackConfigured } from "../../../lib/stack";

export const dynamic = "force-dynamic";

type IdentityRouteDependencies = {
  readonly isConfigured: () => boolean;
  readonly getUser: (
    request: Request,
  ) => Promise<{
    readonly id: string;
    readonly isAnonymous: boolean;
    readonly clientReadOnlyMetadata?: unknown;
  } | null>;
};

const defaultDependencies: IdentityRouteDependencies = {
  isConfigured: isStackConfigured,
  getUser: (request) => getStackServerApp().getUser({
      or: "return-null",
      tokenStore: request as unknown as {
        headers: { get(name: string): string | null };
      },
    }),
};

export const GET = makeAnalyticsIdentityHandler();

export function makeAnalyticsIdentityHandler(
  dependencies: IdentityRouteDependencies = defaultDependencies,
) {
  return async function GET(request: Request): Promise<NextResponse> {
    if (!dependencies.isConfigured()) return identityResponse(null);

    const user = await dependencies.getUser(request);
    // Stack anonymous checkout users must not replace PostHog's browser-level
    // anonymous identity. They become canonical only after account conversion.
    return identityResponse(user && !user.isAnonymous
      ? { id: user.id, plan: analyticsPlan(user.clientReadOnlyMetadata) }
      : null);
  };
}

function analyticsPlan(metadata: unknown): "free" | "pro" | "team" {
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
    return "free";
  }
  const plan = (metadata as Record<string, unknown>).cmuxPlan;
  return plan === "pro" || plan === "team" ? plan : "free";
}

function identityResponse(
  user: {
    readonly id: string;
    readonly plan: "free" | "pro" | "team";
  } | null,
): NextResponse {
  return NextResponse.json(
    { user },
    { headers: { "Cache-Control": "private, no-store" } },
  );
}
