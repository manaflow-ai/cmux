import * as cloudVmHealthRoute from "@/app/api/admin/cloud-vm-health/route";
import * as paywallLabRoute from "@/app/api/admin/paywall-lab/route";
import type { NextRequest } from "next/server";
import { dashboardOS, requireDashboardOrigin } from "./base";
import { callRoute } from "./route-call";
import { cloudVmHealthSchema, paywallLabPauseInputSchema, paywallLabPauseSchema, paywallLabSchema } from "./schemas/ops";

/**
 * Staff-only operations views. Each procedure runs the matching
 * `/api/admin/*` route in process, so the admin gate (verified company email
 * or active admin member) is the same one the REST API enforces. Non-staff get
 * its 403, which the screen renders as not found.
 */
const opsOS = dashboardOS.use(requireDashboardOrigin);

const cloudVmHealth = opsOS
  .output(cloudVmHealthSchema)
  .handler(async ({ context }) =>
    cloudVmHealthSchema.parse(await callRoute(
      context,
      (request: Request) => cloudVmHealthRoute.GET(request as NextRequest),
      { method: "GET", path: "/api/admin/cloud-vm-health" },
    ))
  );

/** The Paywall Lab: every paywall and pricing experiment, as users see it. */
const paywallLab = opsOS
  .output(paywallLabSchema)
  .handler(async ({ context }) =>
    paywallLabSchema.parse(await callRoute(
      context,
      (request: Request) => paywallLabRoute.GET(request as NextRequest),
      { method: "GET", path: "/api/admin/paywall-lab" },
    ))
  );

/** The Paywall Lab kill switch: pause sends every visitor to control; resume restores the split. */
const paywallLabSetPaused = opsOS
  .input(paywallLabPauseInputSchema)
  .output(paywallLabPauseSchema)
  .handler(async ({ context, input }) =>
    paywallLabPauseSchema.parse(await callRoute(
      context,
      (request: Request) => paywallLabRoute.POST(request as NextRequest),
      { method: "POST", path: "/api/admin/paywall-lab", body: input },
    ))
  );

export const opsRouter = { cloudVmHealth, paywallLab, paywallLabSetPaused };
