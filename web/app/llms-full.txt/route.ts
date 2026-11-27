import { NextResponse } from "next/server";
import { headersForLlmsTxt } from "../lib/agent-page-markdown";
import { buildNextDocsFullText } from "../lib/next-docs-text";

export function GET(request: Request) {
  return new NextResponse(buildNextDocsFullText(new URL(request.url).origin), {
    headers: headersForLlmsTxt(),
  });
}
