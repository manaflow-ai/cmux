import { NextResponse, type NextRequest } from "next/server";

import { requestOrigin } from "../../../lib/request-origin";
import { verifyEmailCode } from "../../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../../services/auth/hexclave/config";
import { refuseFormPost } from "../../../../services/auth/hexclave/formFailure";
import {
  formString,
  isSameOriginFormPost,
} from "../../../../services/auth/hexclave/formRequest";

const VERIFICATION_PATH = "/handler/email-verification";

/** Spends the single-use verification code the confirmation page carried. */
export async function POST(request: NextRequest): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const config = hexclaveClientConfig();
  if (!config) return refuseFormPost(origin, "not_configured");
  if (!isSameOriginFormPost(request, origin)) {
    return refuseFormPost(origin, "cross_origin");
  }

  const form = await request.formData();
  const code = formString(form, "code");
  const verified = code ? (await verifyEmailCode(config, code)).ok : false;

  const url = new URL(VERIFICATION_PATH, origin);
  url.searchParams.set("verified", verified ? "1" : "0");
  return NextResponse.redirect(url);
}
