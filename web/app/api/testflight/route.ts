import { type NextRequest, NextResponse } from "next/server";

import { localizedVaultPath, vaultSignInHref } from "../../lib/vault-auth";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { locales, routing } from "../../../i18n/routing";
import {
  enrollTester,
  recordProTestflightEnrollmentEmail,
  removeProTesterAccess,
  removeTester,
} from "../../../services/asc/testflight";
import { isAscConfigured } from "../../../services/asc/client";
import {
  isTestflightEligible,
  type ProMetadataJson,
} from "../../../services/billing/pro";
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

    const stackApp = getStackServerApp();
    const user = await stackApp.getUser({ or: "return-null" });
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
      // Eligibility checks and other billing paths can update Stack metadata.
      // Stack user objects are immutable snapshots, so reload before the
      // read-modify-write that records exact TestFlight ownership.
      const freshUser = await stackApp.getUser(user.id);
      if (!freshUser || freshUser.id !== user.id) {
        return testflightRedirect(request, "error");
      }
      const freshEmail = normalizedEmail(freshUser.primaryEmail);
      if (!freshEmail) return testflightRedirect(request, "needs_email");
      // Persist the exact address before the ASC mutation. If ASC fails, a
      // retry is harmless; if it succeeds, future email changes cannot orphan
      // this Pro-group enrollment during leave, lapse, or account deletion.
      await recordProTestflightEnrollmentEmail(freshUser, freshEmail);
      const name = splitDisplayName(freshUser.displayName);
      await enrollTester(freshEmail, name.firstName, name.lastName);
      return testflightRedirect(request, "joined");
    }

    const freshUser = await stackApp.getUser(user.id);
    if (!freshUser) return testflightRedirect(request, "error");
    await removeProTesterAccess(
      normalizedEmail(freshUser.primaryEmail),
      freshUser.clientReadOnlyMetadata,
      removeTester,
      {
        updateMetadata: (clientReadOnlyMetadata) => freshUser.update({
          clientReadOnlyMetadata: clientReadOnlyMetadata as ProMetadataJson,
        }),
      },
    );
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
