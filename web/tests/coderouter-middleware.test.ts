import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

describe("coderouter middleware", () => {
  test("serves the same dedicated landing page on cmux.com/coderouter", () => {
    const response = middleware(
      new NextRequest("https://cmux.com/coderouter", {
        headers: { host: "cmux.com" },
      }),
    );

    expect(response.headers.get("x-middleware-rewrite")).toBeNull();
    expect(response.headers.get("x-middleware-next")).toBe("1");
  });

  test("serves a dedicated landing page on coderouter.dev", () => {
    const response = middleware(
      new NextRequest("https://coderouter.dev/", {
        headers: { host: "coderouter.dev" },
      }),
    );

    expect(response.headers.get("x-middleware-rewrite")).toBe(
      "https://coderouter.dev/coderouter",
    );
  });

  test("does not localize the OpenAI-compatible data-plane route", () => {
    const response = middleware(
      new NextRequest("https://coderouter.dev/v1/responses", {
        method: "POST",
        headers: { "content-type": "application/json" },
      }),
    );

    expect(response.headers.get("x-middleware-rewrite")).toBeNull();
    expect(response.headers.get("x-middleware-next")).toBe("1");
  });

  test("does not localize Pi's Codex-compatible data-plane route", () => {
    const response = middleware(
      new NextRequest("https://coderouter.dev/v1/codex/responses", {
        method: "POST",
        headers: { "content-type": "application/json" },
      }),
    );

    expect(response.headers.get("x-middleware-rewrite")).toBeNull();
    expect(response.headers.get("x-middleware-next")).toBe("1");
  });

  test("forwards the localized dashboard destination to the server auth gate", () => {
    const response = middleware(
      new NextRequest(
        "https://cmux.com/ja/dashboard/coderouter?team=team-1",
        { headers: { "x-cmux-dashboard-return-path": "/pricing" } },
      ),
    );

    expect(
      response.headers.get("x-middleware-request-x-cmux-dashboard-return-path"),
    ).toBe("/dashboard/coderouter?team=team-1");
  });

  test("keeps a dashboard POST body while adding the auth return path", async () => {
    const request = new NextRequest("https://cmux.com/en/dashboard/testflight", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "action=join",
    });
    const response = middleware(request);

    expect(await request.text()).toBe("action=join");
    expect(
      response.headers.get("x-middleware-request-x-cmux-dashboard-return-path"),
    ).toBe("/dashboard/testflight");
  });
});
