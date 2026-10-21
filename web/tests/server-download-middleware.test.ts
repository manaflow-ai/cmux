import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

const machinePaths = [
  "/server",
  "/server/",
  "/server/channel/stable",
  "/server/channel/beta/aarch64-darwin/v",
  "/server/packages",
  "/server/not-published",
];

describe("server download namespace", () => {
  for (const locale of ["en", "ja"]) {
    test.each(machinePaths)(`keeps %s out of ${locale} page routing`, (path) => {
      const response = middleware(new NextRequest(`https://cmux.com${path}`, {
        headers: { host: "cmux.com", "accept-language": locale },
      }));

      expect(response.headers.get("location")).toBeNull();
      expect(response.headers.get("x-middleware-rewrite")).toBeNull();
      expect(response.headers.get("x-middleware-next")).toBe("1");
      expect(response.headers.get("set-cookie")).toBeNull();
    });
  }

  test.each([
    "/server/install.sh",
    "/server/install.ps1",
    "/server/channel/stable/aarch64-darwin/latest.json",
    "/server/channel/stable/aarch64-darwin/latest.json.sig",
  ])("continues serving file endpoint %s without localization", (path) => {
    const response = middleware(new NextRequest(`https://cmux.com${path}`, {
      headers: { host: "cmux.com", "accept-language": "ja" },
    }));
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("x-middleware-rewrite")).toBeNull();
    expect(response.headers.get("x-middleware-next")).toBe("1");
  });

  test.each(["/servers", "/serverless", "/server-admin"])(
    "keeps lookalike page %s in locale routing",
    (path) => {
      const response = middleware(new NextRequest(`https://cmux.com${path}`, {
        headers: { host: "cmux.com", "accept-language": "ja" },
      }));
      const destination = response.headers.get("location") ?? response.headers.get("x-middleware-rewrite");
      expect(destination).toContain(`/ja${path}`);
    },
  );
});
