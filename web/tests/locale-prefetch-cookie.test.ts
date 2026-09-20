import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

describe("locale preference during prefetch", () => {
  const prefetchHeaders: Record<string, string>[] = [
    { "next-router-prefetch": "1", rsc: "1" },
    { "next-router-prefetch": "2", rsc: "1" },
    { "next-router-prefetch": "3", rsc: "1" },
    { purpose: "prefetch" },
  ];
  for (const headers of prefetchHeaders) {
    test(`does not replace an explicit locale preference for ${JSON.stringify(headers)}`, () => {
      const response = middleware(new NextRequest("https://cmux.com/ko/blog/cmux-vault", {
        headers: { host: "cmux.com", cookie: "NEXT_LOCALE=en", ...headers },
      }));

      expect(response.status).toBe(200);
      expect(response.headers.get("set-cookie")).toBeNull();
      expect(response.headers.get("x-middleware-set-cookie")).toBeNull();
      expect(response.cookies.get("NEXT_LOCALE")).toBeUndefined();
      expect(response.headers.get("x-middleware-request-x-next-intl-locale")).toBe("ko");
      expect(response.headers.get("x-middleware-next")).toBe("1");

      response.cookies.set("unrelated", "kept");
      expect(response.headers.get("set-cookie")).not.toContain("NEXT_LOCALE");
    });
  }

  test("still persists the destination locale for a real navigation", () => {
    const response = middleware(new NextRequest("https://cmux.com/ko/blog/cmux-vault", {
      headers: { host: "cmux.com", cookie: "NEXT_LOCALE=en", rsc: "1" },
    }));

    expect(response.cookies.get("NEXT_LOCALE")?.value).toBe("ko");
    expect(response.headers.get("set-cookie")).toContain("NEXT_LOCALE=ko");
  });
});
