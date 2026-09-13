import { z } from "zod";

import { isAscConfigured } from "../../../services/asc/client";
import { testerGroupStatus } from "../../../services/asc/testflight";
import { isTestflightEligible } from "../../../services/billing/pro";
import { captureAscError } from "../../../services/errors";
import { os, requireAuth } from "../base";

const statusSchema = z.object({
  status: z.enum(["ineligible", "needs_email", "unavailable", "joinable", "enrolled"]),
  email: z.string().nullable(),
  state: z.string().nullable(),
});

export const testflightStatusProcedure = os
  .route({
    method: "GET",
    path: "/dashboard/testflight/status",
    operationId: "dashboard.testflight.status",
    summary: "Get the authenticated user's TestFlight status",
    tags: ["Dashboard"],
    successStatus: 200,
  })
  .output(statusSchema)
  .use(requireAuth)
  .handler(async ({ context }) => {
    const email = normalizeEmail(context.user.primaryEmail);
    const eligible = await isTestflightEligible(context.user);
    if (!eligible) return { status: "ineligible" as const, email, state: null };
    if (!email) return { status: "needs_email" as const, email: null, state: null };
    if (!isAscConfigured()) return { status: "unavailable" as const, email, state: null };

    try {
      const result = await testerGroupStatus(email);
      return {
        status: result.enrolled ? ("enrolled" as const) : ("joinable" as const),
        email,
        state: result.state ?? null,
      };
    } catch (error) {
      captureAscError(error, { page: "/dashboard/testflight", stackUserId: context.user.id, email });
      return { status: "unavailable" as const, email, state: null };
    }
  });

function normalizeEmail(email: string | null | undefined) {
  const normalized = email?.trim().toLowerCase();
  return normalized || null;
}

