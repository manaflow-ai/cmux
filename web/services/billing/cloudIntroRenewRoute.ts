import { NextResponse, type NextRequest } from "next/server";
import type Stripe from "stripe";

import { requestOrigin } from "../../app/lib/request-origin";
import { vaultSignInHref } from "../../app/lib/vault-auth";
import { captureBillingError } from "../errors";
import { isCloudIntroEnabled } from "./cloudIntro";
import { createDrizzleCloudIntroRenewTurnOffStore, type CloudIntroRenewTurnOffStore } from "./cloudIntroRenewal";
import { CLOUD_INTRO_PASS_PARAM } from "./cloudIntroStatements";
import { stripe as defaultStripe } from "./stripe";

/**
 * `POST /api/billing/cloud-pass/renew`: turn the $1 pass's later Plus charge
 * off for the signed-in buyer and detach the saved card. A form post is
 * answered with a 303 to Plan & billing (`?pass=renew-off`, or
 * `?pass=renew-too-late` once a charge went through); `?format=json` answers
 * the outcome as JSON. Signed out goes to sign-in first. With the pass flag
 * off it answers 404; a foreign Origin is refused.
 */
export const CLOUD_INTRO_RENEW_OFF_PATH = "/api/billing/cloud-pass/renew";

type RenewUser = { readonly id: string; readonly isAnonymous?: boolean };

export type CloudIntroRenewRouteContext = {
  readonly stackServerApp: () => Promise<{
    getUser(options: { or: "return-null" }): Promise<RenewUser | null>;
  } | null>;
};

export type CloudIntroRenewRouteDependencies = {
  readonly env?: Record<string, string | undefined>;
  readonly now?: () => Date;
  readonly store?: CloudIntroRenewTurnOffStore;
  readonly stripe?: () => { readonly paymentMethods: Pick<Stripe["paymentMethods"], "detach"> };
};

type Outcome = { readonly status: string; readonly path: string };

const BILLING = "/dashboard/billing";

export async function cloudIntroRenewResponse(
  request: NextRequest,
  context: CloudIntroRenewRouteContext,
  dependencies: CloudIntroRenewRouteDependencies = {},
): Promise<NextResponse> {
  if (!isCloudIntroEnabled(dependencies.env ?? process.env)) return new NextResponse(null, { status: 404 });
  if (!isSameOrigin(request)) return NextResponse.json({ error: "forbidden" }, { status: 403 });
  const outcome = await resolveOutcome(context, dependencies);
  const url = new URL(outcome.path, requestOrigin(request));
  if (request.nextUrl.searchParams.get("format") === "json") {
    return NextResponse.json({ status: outcome.status, url: url.toString() });
  }
  return NextResponse.redirect(url, 303);
}

async function resolveOutcome(
  context: CloudIntroRenewRouteContext,
  dependencies: CloudIntroRenewRouteDependencies,
): Promise<Outcome> {
  try {
    const app = await context.stackServerApp();
    if (!app) return { status: "error", path: `${BILLING}?billing=error` };
    const user = await app.getUser({ or: "return-null" });
    if (!user || user.isAnonymous) {
      return { status: "sign_in", path: vaultSignInHref(`${BILLING}?${CLOUD_INTRO_PASS_PARAM}=renew`) };
    }
    const store = dependencies.store ?? createDrizzleCloudIntroRenewTurnOffStore();
    const result = await store.turnOff(user.id, dependencies.now?.() ?? new Date());
    if (result.status === "too_late") return { status: "too_late", path: `${BILLING}?${CLOUD_INTRO_PASS_PARAM}=renew-too-late` };
    if (result.status === "off" && result.paymentMethodId) {
      // The charge is already off on the row; a failed detach only leaves an unused card on file.
      try {
        await (dependencies.stripe ?? defaultStripe)().paymentMethods.detach(result.paymentMethodId);
      } catch (error) {
        captureBillingError(error, { route: CLOUD_INTRO_RENEW_OFF_PATH, operation: "detach_saved_card" });
      }
    }
    return { status: result.status, path: `${BILLING}?${CLOUD_INTRO_PASS_PARAM}=renew-off` };
  } catch (error) {
    captureBillingError(error, { route: CLOUD_INTRO_RENEW_OFF_PATH });
    return { status: "error", path: `${BILLING}?billing=error` };
  }
}

function isSameOrigin(request: NextRequest): boolean {
  const origin = request.headers.get("origin");
  if (!origin) return true;
  return origin === request.nextUrl.origin || origin === requestOrigin(request);
}
