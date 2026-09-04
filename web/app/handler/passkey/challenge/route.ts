import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { initiatePasskeyAuthentication } from "../../../../services/auth/hexclave/auth";
import { authErrorKeyForCode } from "../../../../services/auth/hexclave/errorCodes";
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
    // The island only needs to know the attempt failed. Passing the upstream
    // code through would put auth-service internals on the page.
    return NextResponse.json(
      { error: authErrorKeyForCode(result.error.code, "passkeyFailed") },
      { status: 502 },
    );
  }
  return NextResponse.json({
    options_json: result.value.optionsJSON,
    code: result.value.code,
  });
}
