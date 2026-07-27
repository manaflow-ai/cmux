import { NextResponse } from "next/server";
import { buildLlmsText } from "../lib/agent-page-paths";
import { headersForLlmsTxt } from "../lib/agent-page-markdown";

export const dynamic = "force-dynamic";

export function GET(request: Request) {
  return new NextResponse(buildLlmsText(new URL(request.url).origin), {
    headers: headersForLlmsTxt(),
  });
}
