import { type NextRequest, NextResponse } from "next/server";

import { localizedVaultPath, vaultSignInHref } from "../../lib/vault-auth";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { cloudDb } from "../../../db/client";
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
import { withAccountDeletionUserMutation } from "../../../services/account/deletionLock";
import { browserMutationOriginAllowed } from "../../../services/vms/routeHelpers";


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

    const result = await withAccountDeletionUserMutation(
      cloudDb(),
      user.id,
      async (mutationLease) => {
        if (action === "join") {
          const email = normalizedEmail(user.primaryEmail);
          if (!email) return "needs_email" as const;
          if (!(await isTestflightEligible(user))) {
            return "ineligible" as const;
          }
          // Eligibility checks and other billing paths can update Stack
          // metadata. Reload before recording exact TestFlight ownership.
          const freshUser = await stackApp.getUser(user.id);
          if (!freshUser || freshUser.id !== user.id) {
            return "error" as const;
          }
          const freshEmail = normalizedEmail(freshUser.primaryEmail);
          if (!freshEmail) return "needs_email" as const;
          // Persist the exact address before the ASC mutation. If ASC fails, a
          // retry is harmless; if it succeeds, future email changes cannot
          // orphan this Pro-group enrollment.
          await recordProTestflightEnrollmentEmail(
            freshUser,
            freshEmail,
            mutationLease,
          );
          const name = splitDisplayName(freshUser.displayName);
          await mutationLease.refresh();
          await enrollTester(freshEmail, name.firstName, name.lastName);
          if (!(await isTestflightEligible(freshUser))) {
            // Protect against a non-cooperating eligibility writer. The shared
            // lock handles cmux billing updates; this compensation closes any
            // remaining change that becomes visible during ASC enrollment.
            const compensationUser = await stackApp.getUser(user.id);
            await removeProTesterAccess(
              freshEmail,
              compensationUser?.clientReadOnlyMetadata ??
                freshUser.clientReadOnlyMetadata,
              removeTester,
              compensationUser
                ? {
                    beforeExternalMutation: mutationLease.refresh,
                    updateMetadata: (clientReadOnlyMetadata) =>
                      compensationUser.update({
                        clientReadOnlyMetadata:
                          clientReadOnlyMetadata as ProMetadataJson,
                      }),
                  }
                : undefined,
            );
            return "ineligible" as const;
          }
          return "joined" as const;
        }

        const freshUser = await stackApp.getUser(user.id);
        if (!freshUser) return "error" as const;
        await removeProTesterAccess(
          normalizedEmail(freshUser.primaryEmail),
          freshUser.clientReadOnlyMetadata,
          removeTester,
          {
            beforeExternalMutation: mutationLease.refresh,
            updateMetadata: (clientReadOnlyMetadata) => freshUser.update({
              clientReadOnlyMetadata: clientReadOnlyMetadata as ProMetadataJson,
            }),
          },
        );
        return "left" as const;
      },
    );
    return testflightRedirect(request, result);
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
