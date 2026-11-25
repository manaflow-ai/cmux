import type { NextRequest, NextResponse } from "next/server";

import { cloudIntroRenewResponse } from "../../../../../services/billing/cloudIntroRenewRoute";

/** Turns the $1 pass's later Plus charge off (RFD 0052); see services/billing/cloudIntroRenewRoute.ts. */
export async function POST(request: NextRequest): Promise<NextResponse> {
  return await cloudIntroRenewResponse(request, {
    stackServerApp: async () => {
      const { getStackServerApp, isStackConfigured } = await import("../../../../lib/stack");
      return isStackConfigured() ? getStackServerApp() : null;
    },
  });
}
