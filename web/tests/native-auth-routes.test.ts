import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.RESEND_API_KEY ??= "test";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "test@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test";
process.env.STACK_SECRET_SERVER_KEY ??= "test";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "454ecd03-1db2-4050-845e-4ce5b0cd9895";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "test";

const { GET: nativeSignInGET } = await import("../app/handler/native-sign-in/route");
const { isAllowedNativeReturnTo } = await import("../app/handler/after-sign-in/route");

describe("native auth routes", () => {
  test("preserves LAN origin when redirecting native sign-in to Stack", () => {
    const nativeReturnTo = "cmux-dev-sc2://auth-callback?cmux_auth_state=state-1";
    const afterSignIn = new URL("http://172.20.21.125:4177/handler/after-sign-in");
    afterSignIn.searchParams.set("native_app_return_to", nativeReturnTo);
    const requestURL = new URL("http://localhost:4177/handler/native-sign-in");
    requestURL.searchParams.set("after_auth_return_to", afterSignIn.toString());

    const response = nativeSignInGET(new NextRequest(requestURL, {
      headers: {
        host: "172.20.21.125:4177",
      },
    }));

    expect(response.status).toBe(307);
    const location = response.headers.get("location");
    expect(location?.startsWith("http://172.20.21.125:4177/handler/sign-in?")).toBe(true);
    expect(new URL(location!).searchParams.get("after_auth_return_to")?.startsWith(
      "http://172.20.21.125:4177/handler/after-sign-in?"
    )).toBe(true);
  });

  test("allows configured per-tag native callback schemes from a dev LAN host", () => {
    const previousScheme = process.env.CMUX_AUTH_CALLBACK_SCHEME;
    process.env.CMUX_AUTH_CALLBACK_SCHEME = "cmux-dev-sc2";
    try {
      const request = new NextRequest("http://localhost:4177/handler/after-sign-in", {
        headers: {
          host: "172.20.21.125:4177",
        },
      });

      expect(isAllowedNativeReturnTo(
        "cmux-dev-sc2://auth-callback?cmux_auth_state=state-1",
        request
      )).toBe(true);
    } finally {
      restoreEnv("CMUX_AUTH_CALLBACK_SCHEME", previousScheme);
    }
  });
});

function restoreEnv(key: string, value: string | undefined) {
  if (value === undefined) {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
