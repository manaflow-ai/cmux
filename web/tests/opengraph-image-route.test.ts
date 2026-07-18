import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import { GET } from "../app/[locale]/opengraph-image/route";
import {
  openGraphImageResponse,
  renderOpenGraphImage,
} from "../app/lib/open-graph-image";
import { articleSchema } from "../app/[locale]/components/json-ld";
import { openGraphImage } from "../i18n/seo";
import { routing } from "../i18n/routing";
import middleware from "../proxy";

describe("Open Graph image discovery", () => {
  test("serves the advertised image endpoint for every locale", async () => {
    for (const locale of routing.locales) {
      const advertisedUrl = openGraphImage(locale).url;
      const publicPath = new URL(advertisedUrl).pathname;
      const expectedPath =
        locale === routing.defaultLocale
          ? "/opengraph-image"
          : `/${locale}/opengraph-image`;
      expect(publicPath).toBe(expectedPath);

      const middlewareResponse = middleware(new NextRequest(advertisedUrl));
      const rewrite = middlewareResponse.headers.get("x-middleware-rewrite");
      expect(rewrite).toBeNull();

      let renderedLocale: string | undefined;
      const response = await openGraphImageResponse(locale, (candidate) => {
        renderedLocale = candidate;
        return new Response(new Uint8Array([137, 80, 78, 71]), {
          headers: { "Content-Type": "image/png" },
        });
      });

      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toBe("image/png");
      expect(renderedLocale).toBe(locale);
    }
  });

  test("rejects unsupported locale image routes", async () => {
    const response = await GET(
      new Request("https://cmux.com/xx/opengraph-image"),
      { params: Promise.resolve({ locale: "xx" }) },
    );

    expect(response.status).toBe(404);
  });

  test("renders the Arabic image response body", async () => {
    const response = await renderOpenGraphImage("ar");
    const body = new Uint8Array(await response.arrayBuffer());

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("image/png");
    expect([...body.slice(0, 8)]).toEqual([137, 80, 78, 71, 13, 10, 26, 10]);
  });

  test("uses the crawlable localized image in Article structured data", () => {
    const article = articleSchema({
      locale: "ja",
      path: "/blog/cmux-fork",
      headline: "Introducing cmux Fork",
      description: "Fork an agent conversation.",
      datePublished: "2026-07-14T00:00:00Z",
    });

    expect(article.image).toBe("https://cmux.com/ja/opengraph-image");
  });
});
