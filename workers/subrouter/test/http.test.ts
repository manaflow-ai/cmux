import { describe, expect, test } from "bun:test";
import { upstreamErrorResponse } from "../src/http";

describe("upstreamErrorResponse", () => {
  test("does not include upstream error details", async () => {
    const response = upstreamErrorResponse();

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "upstream_error" });
  });
});
