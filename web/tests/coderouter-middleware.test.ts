import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

describe("CodeRouter middleware", () => {
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
