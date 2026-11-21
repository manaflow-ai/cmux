import { describe, expect, test } from "bun:test";

import { BADGE_SIZES, badgeSvg, parseBadgeSize, parseBadgeTheme } from "../app/extensions/_lib/badge";
import { GET } from "../app/extensions/badge.svg/route";

function dimensions(svg: string): { width: number; height: number } {
  const match = /^<svg[^>]* width="([\d.]+)" height="([\d.]+)"/.exec(svg);
  if (!match) throw new Error("svg has no size");
  return { width: Number(match[1]), height: Number(match[2]) };
}

describe("Get it on cmux badge", () => {
  test("names itself for screen readers and as an image title", () => {
    const svg = badgeSvg();
    expect(svg).toContain('aria-label="Get it on cmux"');
    expect(svg).toContain("<title>Get it on cmux</title>");
    expect(svg).toContain('role="img"');
  });

  test("sizes differ and keep the artwork's proportions", () => {
    const small = dimensions(badgeSvg({ size: "small" }));
    const regular = dimensions(badgeSvg());
    const large = dimensions(badgeSvg({ size: "large" }));
    expect(small).toEqual(BADGE_SIZES.small);
    expect(regular).toEqual(BADGE_SIZES.default);
    expect(large).toEqual(BADGE_SIZES.large);
    expect(small.width).toBeLessThan(regular.width);
    expect(regular.width).toBeLessThan(large.width);
    for (const size of [small, regular, large]) {
      expect(Math.abs(size.width / size.height - 122 / 44)).toBeLessThan(0.02);
    }
  });

  test("unknown size and theme values fall back to the defaults", () => {
    expect(parseBadgeSize("huge")).toBe("default");
    expect(parseBadgeSize(null)).toBe("default");
    expect(parseBadgeSize("small")).toBe("small");
    expect(parseBadgeTheme("neon")).toBe("dark");
    expect(parseBadgeTheme("light")).toBe("light");
  });

  test("the light theme draws on white", () => {
    expect(badgeSvg({ theme: "light" })).toContain('fill="#fff" stroke="#000"');
    expect(badgeSvg()).toContain('fill="#000" stroke="#a6a6a6"');
  });

  test("carries no script, link, external reference or web font", () => {
    for (const size of ["small", "default", "large"] as const) {
      for (const theme of ["dark", "light"] as const) {
        const svg = badgeSvg({ size, theme });
        expect(svg).not.toMatch(/<script|<a[\s>]|<foreignObject|<image|<style|@import|<text/i);
        expect(svg).not.toMatch(/\bhref=|xlink:|\bon[a-z]+=/i);
        expect(svg).not.toMatch(/url\((?!#)/);
        expect(svg).not.toContain("NaN");
        // The only URL is the SVG namespace.
        expect(svg.match(/https?:\/\/[^"]+/g)).toEqual(["http://www.w3.org/2000/svg"]);
      }
    }
  });

  test("the route serves the SVG with long-lived cache headers and falls back on bad params", async () => {
    const response = GET(new Request("https://cmux.com/extensions/badge.svg?size=huge&theme=neon"));
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("image/svg+xml; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=86400, s-maxage=31536000, stale-while-revalidate=604800",
    );
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(await response.text()).toBe(badgeSvg());
  });
});
