import type { NextRequest, NextResponse } from "next/server";

import { cloudTasteResponse } from "../../../../services/billing/cloudTasteRoute";

/** The cmux Cloud free week (RFD 0052); see services/billing/cloudTasteRoute.ts. */
export async function POST(request: NextRequest): Promise<NextResponse> {
  return await cloudTasteResponse(request, {
    stackServerApp: async () => {
      const { getStackServerApp, isStackConfigured } = await import("../../../lib/stack");
      return isStackConfigured() ? getStackServerApp() : null;
    },
  });
}
