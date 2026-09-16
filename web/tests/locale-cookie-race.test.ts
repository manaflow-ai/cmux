import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

function request(path: string, headers: Record<string, string> = {}) {
  return new NextRequest(`https://cmux.com${path}`, {
    headers: { cookie: "NEXT_LOCALE=en", "accept-language": "ko", ...headers },
  });
}

describe("locale preference ownership", () => {
  for (const [kind, headers] of [
    ["RSC navigation", { rsc: "1" }],
    ["router prefetch", { rsc: "1", "next-router-prefetch": "1" }],
    ["HTML prefetch", { purpose: "prefetch" }],
    ["browser prefetch", { "sec-purpose": "prefetch" }],
    // Next.js strips its internal RSC headers before invoking Proxy.
    ["normalized browser fetch", { "sec-fetch-dest": "empty", "sec-fetch-mode": "cors" }],
  ] as const) {
    test(`${kind} cannot overwrite a newer explicit language choice`, () => {
      const response = middleware(request("/ko/blog", headers));
      expect(response.status).toBe(200);
      expect(response.headers.get("x-middleware-request-x-next-intl-locale")).toBe("ko");
      expect(response.headers.get("set-cookie")).toBeNull();
      expect(response.headers.get("x-middleware-set-cookie")).toBeNull();
    });
  }

  test("document navigation still remembers an explicitly visited locale", () => {
    const response = middleware(request("/ko/blog", { "sec-fetch-dest": "document" }));
    expect(response.cookies.get("NEXT_LOCALE")?.value).toBe("ko");
  });

  test("background requests still read the selected locale for unprefixed routes", () => {
    const response = middleware(request("/blog", { rsc: "1" }));
    expect(response.status).toBe(200);
    expect(response.headers.get("x-middleware-request-x-next-intl-locale")).toBe("en");
    expect(response.headers.get("location")).toBeNull();
  });
});
