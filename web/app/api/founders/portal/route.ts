import { NextRequest, NextResponse } from "next/server";

import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { isStripeBillingConfigured } from "../../../../services/billing/stripe";
import {
  createFoundersPortalSession,
  resolveFoundersBilling,
  type FoundersBillingResolution,
  type FoundersStackUser,
} from "../../../../services/billing/founders";
import { captureBillingError } from "../../../../services/errors";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type StackServerAppLike = {
  getUser(options: { or: "return-null" }): Promise<FoundersStackUser | null>;
};

type FoundersPortalHandlerDependencies = {
  isStackConfigured?: () => boolean;
  isStripeBillingConfigured?: () => boolean;
  getStackServerApp?: () => StackServerAppLike;
  resolveFoundersBilling?: (
    user: FoundersStackUser,
  ) => Promise<FoundersBillingResolution>;
  createFoundersPortalSession?: (
    customerId: string,
    returnUrl: string,
  ) => Promise<string>;
  captureBillingError?: (
    error: unknown,
    context: { route: string; stackUserId?: string },
  ) => void;
};

export function makeFoundersPortalHandler(
  dependencies: FoundersPortalHandlerDependencies = {},
) {
  return async function GET(request: NextRequest) {
    const stackConfigured = dependencies.isStackConfigured ?? isStackConfigured;
    const stripeConfigured =
      dependencies.isStripeBillingConfigured ?? isStripeBillingConfigured;

    if (!stackConfigured() || !stripeConfigured()) {
      return foundersRedirect(request, "unavailable");
    }

    let stackUserId: string | undefined;
    try {
      const stackApp = (dependencies.getStackServerApp ?? getStackServerApp)();
      const user = await stackApp.getUser({ or: "return-null" });
      if (!user || user.isAnonymous) {
        return NextResponse.redirect(new URL("/founders", request.url), 302);
      }
      stackUserId = user.id;

      const resolution = await (dependencies.resolveFoundersBilling ??
        resolveFoundersBilling)(user);
      if (resolution.status === "email-unverified") {
        return NextResponse.redirect(new URL("/founders", request.url), 302);
      }
      if (resolution.status === "no-subscription") {
        return foundersRedirect(request, "missing");
      }

      const portalUrl = await (dependencies.createFoundersPortalSession ??
        createFoundersPortalSession)(
        resolution.customerId,
        new URL("/founders", request.nextUrl.origin).toString(),
      );
      return NextResponse.redirect(portalUrl, 302);
    } catch (error) {
      (dependencies.captureBillingError ?? captureBillingError)(error, {
        route: "/api/founders/portal",
        stackUserId,
      });
      return foundersRedirect(request, "error");
    }
  };
}

export const GET = makeFoundersPortalHandler();

function foundersRedirect(
  request: NextRequest,
  billing: "unavailable" | "missing" | "error",
) {
  return NextResponse.redirect(
    new URL(`/founders?billing=${billing}`, request.url),
    302,
  );
}
