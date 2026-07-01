import { NextRequest, NextResponse } from "next/server";
import { stackServerApp } from "../../../lib/stack";
import {
  hasActiveProSubscription,
  syncProPlanMetadata,
} from "../../../../services/billing/pro";

export const dynamic = "force-dynamic";

const VERIFY_ATTEMPTS = 4;
const VERIFY_SPACING_MS = 1500;

// Stack's hosted purchase page returns here after payment. Stripe confirms
// asynchronously, so the subscription can lag the redirect by a moment —
// poll briefly (bounded, external system) before deciding.
export async function GET(request: NextRequest) {
  if (!stackServerApp) {
    return NextResponse.redirect(new URL("/pricing", request.url));
  }
  const user = await stackServerApp.getUser({ or: "return-null" });
  if (!user) {
    return NextResponse.redirect(new URL("/pricing", request.url));
  }

  const app = stackServerApp;
  let isPro = false;
  for (let attempt = 0; attempt < VERIFY_ATTEMPTS; attempt++) {
    if (attempt > 0) {
      await new Promise((resolve) => setTimeout(resolve, VERIFY_SPACING_MS));
      // Client gone (edge timeout, closed tab): stop polling. The pending
      // banner's "check again" link re-runs this route, so nothing is lost.
      if (request.signal.aborted) break;
    }
    // App-level lookup each attempt so no per-object store caching can
    // return a stale product list mid-poll.
    isPro = await hasActiveProSubscription({
      listProducts: (options) =>
        app.listProducts({ userId: user.id, ...options }),
    });
    if (isPro) break;
  }

  await syncProPlanMetadata(user, isPro);
  return NextResponse.redirect(
    new URL(
      isPro ? "/pricing?welcome=success" : "/pricing?welcome=pending",
      request.url,
    ),
  );
}
