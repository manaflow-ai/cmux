import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { verifyEmailCode } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import {
  formString,
  isSameOriginFormPost,
} from "../../../../services/auth/hexclave/formRequest";

const VERIFICATION_PATH = "/handler/email-verification";

/** Spends the single-use verification code the confirmation page carried. */
export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return NextResponse.json({ error: "not_configured" }, { status: 404 });
  if (!isSameOriginFormPost(request, origin)) {
    return NextResponse.json({ error: "cross_origin" }, { status: 403 });
  }

  const form = await request.formData();
  const code = formString(form, "code");
  const verified = code ? (await verifyEmailCode(config, code)).ok : false;

  const url = new URL(VERIFICATION_PATH, origin);
  url.searchParams.set("verified", verified ? "1" : "0");
  return NextResponse.redirect(url);
}
