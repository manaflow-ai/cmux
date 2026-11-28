import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../app/lib/request-origin";
import { vaultSignInHref } from "../../app/lib/vault-auth";
import { captureBillingError } from "../errors";
import { isCloudIntroEnabled } from "./cloudIntro";
import type { CloudIntroAccountUser } from "./cloudIntroPasses";
import { cloudIntroLayout } from "./cloudIntroOffer";
import { CLOUD_TASTE_WELCOME, cloudTasteRefusalBillingCode } from "./cloudTaste";
import { defaultCloudTasteDependencies, grantCloudTaste, type CloudTasteDependencies } from "./cloudTasteGrants";

/**
 * `POST /api/billing/cloud-taste`: grant the free week to the signed-in person
 * or say why not. A browser form post is answered with a 303 to the next page:
 * Plan & billing (`?welcome=taste`) on a grant, `/pricing?billing=taste_...`
 * on a refusal, sign-in first when signed out. `?format=json` answers the same
 * outcome as JSON. With the flag off it answers 404, as it did before it
 * existed, and grants nothing.
 */
type TasteUser = CloudIntroAccountUser & { readonly isAnonymous?: boolean };

export type CloudTasteRouteContext = {
  readonly stackServerApp: () => Promise<{
    getUser(options: { or: "return-null" }): Promise<TasteUser | null>;
  } | null>;
};

export type CloudTasteRouteDependencies = Partial<CloudTasteDependencies> & {
  readonly env?: Record<string, string | undefined>;
};

type Outcome =
  | { readonly status: "granted"; readonly path: string; readonly startedAt: string; readonly endsAt: string }
  | { readonly status: "refused" | "sign_in" | "error"; readonly path: string; readonly code?: string };

export async function cloudTasteResponse(
  request: NextRequest,
  context: CloudTasteRouteContext,
  dependencies: CloudTasteRouteDependencies = {},
): Promise<NextResponse> {
  if (!isCloudIntroEnabled(dependencies.env ?? process.env)) return new NextResponse(null, { status: 404 });
  if (!isSameOrigin(request)) return NextResponse.json({ error: "forbidden" }, { status: 403 });
  const outcome = await resolveOutcome(request, context, dependencies);
  const url = new URL(outcome.path, requestOrigin(request));
  if (request.nextUrl.searchParams.get("format") === "json") {
    const body: Record<string, unknown> = { ...outcome, url: url.toString() };
    delete body.path;
    return NextResponse.json(body);
  }
  // 303: the browser follows a form post with a GET.
  return NextResponse.redirect(url, 303);
}

async function resolveOutcome(
  request: NextRequest,
  context: CloudTasteRouteContext,
  dependencies: CloudTasteRouteDependencies,
): Promise<Outcome> {
  try {
    const app = await context.stackServerApp();
    if (!app) return refused("unavailable");
    const user = await app.getUser({ or: "return-null" });
    if (!user || user.isAnonymous) return { status: "sign_in", path: vaultSignInHref(await pricingReturnPath(request)) };
    if (isAccountDeleting(user)) return refused("account_deletion_in_progress");
    const decision = await grantCloudTaste(user, { ...defaultCloudTasteDependencies(), ...dependencies });
    if (decision.status === "refused") return refused(cloudTasteRefusalBillingCode(decision.refusal));
    return {
      status: "granted",
      path: `/dashboard/billing?welcome=${CLOUD_TASTE_WELCOME}`,
      startedAt: decision.grant.startedAt.toISOString(),
      endsAt: decision.grant.endsAt.toISOString(),
    };
  } catch (error) {
    captureBillingError(error, { route: "/api/billing/cloud-taste" });
    return { status: "error", path: "/pricing?billing=error", code: "error" };
  }
}

function refused(code: string): Outcome {
  return { status: "refused", path: `/pricing?billing=${code}`, code };
}

/** Back to the pricing preview in the layout the form was on, to press the button again. */
async function pricingReturnPath(request: NextRequest): Promise<string> {
  const form = await request.formData().catch(() => null);
  const value = form?.get("intro") ?? request.nextUrl.searchParams.get("intro");
  return `/next/pricing?intro=${cloudIntroLayout(typeof value === "string" ? value : undefined)}`;
}

/** A cross-site form cannot spend someone's one free week: a foreign Origin is refused. */
function isSameOrigin(request: NextRequest): boolean {
  const origin = request.headers.get("origin");
  if (!origin) return true;
  return origin === request.nextUrl.origin || origin === requestOrigin(request);
}

function isAccountDeleting(user: CloudIntroAccountUser): boolean {
  const metadata = user.clientReadOnlyMetadata;
  return Boolean(
    metadata && typeof metadata === "object" && (metadata as Record<string, unknown>).cmuxAccountDeleting === true,
  );
}
