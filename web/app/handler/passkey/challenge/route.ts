import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { initiatePasskeyAuthentication } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import { isSameOriginFormPost } from "../../../../services/auth/hexclave/formRequest";

export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });
  if (!isSameOriginFormPost(request, origin)) {
    return NextResponse.json({ error: "cross_origin" }, { status: 403 });
  }

  const result = await initiatePasskeyAuthentication(
    config,
    new URL(origin).hostname,
  );
  if (!result.ok) {
    return NextResponse.json({ error: result.error.code }, { status: 502 });
  }
  return NextResponse.json({
    options_json: result.value.optionsJSON,
    code: result.value.code,
  });
}
