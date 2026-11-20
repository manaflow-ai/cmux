import type { NextRequest } from "next/server";

import { getStackServerApp } from "../../../lib/stack";
import { adminJsonResponse, requireAdmin } from "../../../../services/admin/routeAuth";
import { latestStoredVmHealthReport, readVmHealthStaffView } from "../../../../services/vms/health/staffView";

/**
 * GET /api/admin/cloud-vm-health — the newest stored Cloud VM health sweep,
 * with owner emails for flagged VMs. Staff only (401 signed out, 403 for
 * everyone else). Reads the snapshot the cron wrote; never probes a VM.
 */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const stack = getStackServerApp();
  const view = await readVmHealthStaffView({
    latest: latestStoredVmHealthReport,
    lookupOwner: async (userId) => {
      const user = await stack.getUser(userId);
      return user ? { email: user.primaryEmail ?? null, displayName: user.displayName ?? null } : null;
    },
    now: () => new Date(),
  });
  return adminJsonResponse(view);
}
