import * as cloudVmHealthRoute from "@/app/api/admin/cloud-vm-health/route";
import type { NextRequest } from "next/server";
import { dashboardOS, requireDashboardOrigin } from "./base";
import { callRoute } from "./route-call";
import { cloudVmHealthSchema } from "./schemas/ops";

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

export const opsRouter = { cloudVmHealth };
