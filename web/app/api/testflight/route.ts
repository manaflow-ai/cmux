import { NextRequest, NextResponse } from "next/server";

import { localizedVaultPath, vaultSignInHref } from "../../lib/vault-auth";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { locales, routing } from "../../../i18n/routing";
import { enrollTester, removeTester } from "../../../services/asc/testflight";
import { isAscConfigured } from "../../../services/asc/client";
import { isTestflightEligible } from "../../../services/billing/pro";
import { captureAscError } from "../../../services/errors";
import { browserMutationOriginAllowed } from "../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type TestflightAction = "join" | "leave";

export async function POST(request: NextRequest) {
  let stackUserId: string | undefined;
  let action: TestflightAction | null = null;

  if (!browserMutationOriginAllowed(request)) {
    return testflightRedirect(request, "error");
  }

  try {
    const formData = await request.formData();
    action = testflightAction(formData);
    if (!action) return testflightRedirect(request, "error");

    if (!isStackConfigured()) {
      return testflightRedirect(request, "unavailable");
    }

    const user = await getStackServerApp().getUser({ or: "return-null" });
    if (!user || user.isAnonymous) {
      return NextResponse.redirect(
        new URL(vaultSignInHref(localizedVaultPath(requestLocale(request), "/dashboard/testflight")), request.url),
        303,
      );
    }
    stackUserId = user.id;

    if (!isAscConfigured()) {
      return testflightRedirect(request, "unavailable");
    }

    const email = normalizedEmail(user.primaryEmail);
    if (!email) return testflightRedirect(request, "needs_email");

    if (action === "join") {
      if (!(await isTestflightEligible(user))) {
        return testflightRedirect(request, "ineligible");
      }
      const name = splitDisplayName(user.displayName);
      await enrollTester(email, name.firstName, name.lastName);
      return testflightRedirect(request, "joined");
    }

    await removeTester(email);
    return testflightRedirect(request, "left");
  } catch (error) {
    captureAscError(error, {
      route: "/api/testflight",
      stackUserId,
      action,
    });
    return testflightRedirect(request, "error");
  }
}

function testflightAction(formData: FormData): TestflightAction | null {
  const action = formData.get("action");
  return action === "join" || action === "leave" ? action : null;
}

function normalizedEmail(email: string | null | undefined): string | null {
  const normalized = email?.trim().toLowerCase();
  return normalized ? normalized : null;
}

function splitDisplayName(displayName: string | null | undefined): {
  firstName?: string;
  lastName?: string;
} {
  const parts = displayName?.trim().split(/\s+/).filter(Boolean) ?? [];
  if (parts.length === 0) return {};
  if (parts.length === 1) return { firstName: parts[0] };
  return {
    firstName: parts[0],
    lastName: parts.slice(1).join(" "),
  };
}

function testflightRedirect(
  request: NextRequest,
  testflight:
    | "joined"
    | "left"
    | "error"
    | "ineligible"
    | "needs_email"
    | "unavailable",
) {
  const url = new URL(localizedTestflightPath(request), request.url);
  url.searchParams.set("testflight", testflight);
  return NextResponse.redirect(url, 303);
}

function localizedTestflightPath(request: NextRequest): string {
  const locale = requestLocale(request);
  return locale === routing.defaultLocale
    ? "/dashboard/testflight"
    : `/${locale}/dashboard/testflight`;
}

function requestLocale(request: NextRequest): string {
  const referer = request.headers.get("referer");
  if (referer) {
    try {
      const firstSegment = new URL(referer).pathname.split("/").filter(Boolean)[0];
      if (locales.includes(firstSegment as (typeof locales)[number])) {
        return firstSegment;
      }
    } catch {
      // Ignore malformed referers and fall back to the default locale.
    }
  }
  return routing.defaultLocale;
}
