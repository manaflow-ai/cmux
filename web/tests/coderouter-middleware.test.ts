import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

describe("coderouter middleware", () => {
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
});
