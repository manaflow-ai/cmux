import { NextResponse } from "next/server";

/**
 * The answer a browser form gets when the request never reaches an auth call.
 *
 * These endpoints are POST targets of real forms, so returning a JSON literal
 * would put `{"error":"not_configured"}` on the visitor's screen with no
 * translation and no way forward. `/handler/auth-error` needs no Hexclave
 * configuration to render, which is what makes it safe as the destination when
 * the reason is that Hexclave is not configured.
 */
export function refuseFormPost(
  origin: string,
  reason: "not_configured" | "cross_origin",
): NextResponse {
  const url = new URL("/handler/auth-error", origin);
  url.searchParams.set("code", "generic");
  const response = NextResponse.redirect(url);
  // Not read by the page. It keeps the reason in the response for logs and for
  // anyone reading a HAR, without showing it to the visitor.
  response.headers.set("x-cmux-auth-refused", reason);
  return response;
}
