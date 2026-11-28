import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NextRequest } from "next/server";
import middleware from "../proxy";
import {
  docsLinkFallback,
  fixedDocsLinkFallbackPaths,
} from "../app/lib/docs-link-fallbacks";

const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const docsRoot = path.join(webRoot, "app/[locale]/(landing)/docs");

function locationFor(pathname: string): string | null {
  const response = middleware(
    new NextRequest(`https://cmux.com${pathname}`, {
      headers: { host: "cmux.com" },
    }),
  );
  return response.status === 307 ? response.headers.get("location") : null;
}

describe("docs links with no page", () => {
  test.each([
    ["/docs/agents", "/docs/getting-started"],
    ["/docs/agents/", "/docs/getting-started"],
    ["/docs/cli", "/docs/api"],
    ["/docs/mobile", "/docs/ios"],
    ["/docs/next", "/docs/getting-started"],
    ["/docs/next/agents", "/docs/getting-started"],
    ["/docs/next/cli", "/docs/api"],
    ["/docs/next/settings", "/docs/configuration"],
  ])("cmux.com%s goes to %s", (from, to) => {
    expect(locationFor(from)).toBe(`https://cmux.com${to}`);
  });

  test.each(["/docs/getting-started", "/docs/api", "/docs/ios", "/docs/agents/x", "/docs/nightly/next/agents"])(
    "%s keeps the normal docs route",
    (pathname) => {
      expect(locationFor(pathname)).toBeNull();
    },
  );

  test("every target is a docs page", () => {
    const sources = [...fixedDocsLinkFallbackPaths, "/docs/next", "/docs/next/cli", "/docs/next/remote"];
    for (const source of sources) {
      const target = docsLinkFallback(source);
      expect(target).toBeDefined();
      const page = path.join(docsRoot, (target ?? "").replace(/^\/docs\//u, ""), "page.tsx");
      expect(existsSync(page)).toBe(true);
    }
  });

  // A fallback must never shadow a real page: remove it when the page is added.
  test("no fixed fallback path has a docs page", () => {
    for (const source of fixedDocsLinkFallbackPaths) {
      const dir = path.join(docsRoot, source.replace(/^\/docs\//u, ""));
      expect(existsSync(dir)).toBe(false);
    }
  });

  // When the cmux-next track reaches main, next.config.ts must redirect it
  // (Next.js runs config redirects before this middleware), so its pages win.
  test("a cmux-next docs track in the tree is redirected before the fallback", () => {
    if (!existsSync(path.join(docsRoot, "next"))) return;
    const config = readFileSync(path.join(webRoot, "next.config.ts"), "utf8");
    expect(config).toContain('source: "/docs/next/:slug"');
  });
});
