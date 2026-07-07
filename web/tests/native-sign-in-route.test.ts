import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

const { GET } = await import("../app/handler/native-sign-in/route");

describe("native sign-in route", () => {
  test("sets the handoff cookie as secure when forwarded proto is https", () => {
    const afterSignIn =
      "http://cmux.test/handler/after-sign-in?native_app_return_to=cmux://auth-callback?cmux_auth_state=state-123";

    const response = GET(
      new NextRequest(
        `http://cmux.test/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`,
        {
          headers: {
            "x-forwarded-proto": "https,http",
          },
        },
      ),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toContain("/handler/sign-in");
    expect(response.headers.get("set-cookie")).toContain("Secure");
  });
});
