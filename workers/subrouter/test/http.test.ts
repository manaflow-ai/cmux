import { describe, expect, test } from "bun:test";
import { upstreamErrorResponse } from "../src/http";

describe("upstreamErrorResponse", () => {
  test("does not include upstream error details", async () => {
    const response = upstreamErrorResponse();

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "upstream_error" });
  });

  test("includes sanitized upstream status without body details", async () => {
    const response = upstreamErrorResponse({
      statusCode: 429,
      responseBody: "secret upstream body",
    });

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({
      error: "upstream_error",
      upstream_status: 429,
    });
  });
});
