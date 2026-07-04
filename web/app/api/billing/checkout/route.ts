import { NextRequest, NextResponse } from "next/server";
import { stackServerApp } from "../../../lib/stack";
import {
  PRO_PRODUCT_ID,
  hasActiveProSubscription,
  syncProPlanMetadata,
} from "../../../../services/billing/pro";

export const dynamic = "force-dynamic";

// One-click upgrade entrypoint. Signed-out visitors become anonymous Stack
// users first, then go straight to the hosted purchase page. Stack keeps the
// product grant attached to that anonymous user until the buyer completes
// account setup with an email.
export async function GET(request: NextRequest) {
  if (!stackServerApp) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", request.url));
  }

  const user =
    (await stackServerApp.getUser({ or: "return-null" })) ??
    (await stackServerApp.getUser({ or: "anonymous" }));

  if (await hasActiveProSubscription(user)) {
    await syncProPlanMetadata(user, true);
    return NextResponse.redirect(new URL("/pricing?welcome=active", request.url));
  }

  const returnUrl = new URL("/api/billing/confirm", request.url).toString();
  let checkoutUrl: string;
  try {
    checkoutUrl = await user.createCheckoutUrl({
      productId: PRO_PRODUCT_ID,
      returnUrl,
    });
  } catch (error) {
    if (isAlreadyGrantedError(error)) {
      await syncProPlanMetadata(user, true);
      return NextResponse.redirect(new URL("/pricing?welcome=active", request.url));
    }
    // return_url must be on a domain the Stack project trusts; previews and
    // local dev ports may not be. The purchase still works without it — the
    // buyer stays on the hosted receipt, and Pro state is picked up by the
    // read-time reconcile on VM create or the next visit to this route.
    try {
      checkoutUrl = await user.createCheckoutUrl({ productId: PRO_PRODUCT_ID });
    } catch (retryError) {
      console.error("[Billing] createCheckoutUrl failed", error, retryError);
      return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
    }
  }
  return NextResponse.redirect(checkoutUrl);
}

function isAlreadyGrantedError(error: unknown): boolean {
  const text =
    error instanceof Error ? `${error.name} ${error.message}` : String(error);
  return /already.{0,20}granted/i.test(text);
}
