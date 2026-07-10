import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

function request(path: string) {
  return new NextRequest(`https://cmux.test${path}`, {
    headers: { host: "cmux.test" },
  });
}

describe("proxy metadata routes", () => {
  test("does not redirect locale-prefixed Next metadata image routes", () => {
    for (const path of [
      "/en/opengraph-image-e6it15?f656b4354be9c5cd",
      "/ja/opengraph-image-e6it15?f656b4354be9c5cd",
      "/en/twitter-image-e6it15?f656b4354be9c5cd",
      "/en/icon?f656b4354be9c5cd",
      "/en/apple-icon?f656b4354be9c5cd",
    ]) {
      const response = middleware(request(path));

      expect(response.status).toBe(200);
      expect(response.headers.get("location")).toBeNull();
    }
  });

  test("keeps default-locale redirects for normal pages", () => {
    const response = middleware(request("/en/docs"));

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://cmux.test/docs");
  });
});
