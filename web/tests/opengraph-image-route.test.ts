import { describe, expect, test } from "bun:test";
import { readFile } from "fs/promises";
import { NextRequest } from "next/server";
import { join } from "path";
import sharp from "sharp";
import {
  dynamic as localizedImageDynamic,
  GET,
} from "../app/[locale]/opengraph-image/route";
import {
  openGraphLocaleFonts,
  openGraphTaglineFallbackFont,
} from "../app/lib/open-graph-font-config";
import { openGraphImageResponse } from "../app/lib/open-graph-image";
import { dynamic as defaultImageDynamic } from "../app/opengraph-image/route";
import { articleSchema } from "../app/[locale]/components/json-ld";
import { openGraphImage, openGraphImageTagline } from "../i18n/seo";
import { routing } from "../i18n/routing";
import middleware from "../proxy";
import { fontSupportsCodePoint } from "./font-cmap";

function renderLocaleOpenGraphImage(locale: string): Promise<Response> {
  return GET(new Request(`https://cmux.com/${locale}/opengraph-image`), {
    params: Promise.resolve({ locale }),
  });
}

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

  test("bypasses locale middleware for both default endpoint forms", () => {
    for (const path of ["/opengraph-image", "/opengraph-image/"]) {
      const response = middleware(new NextRequest(`https://cmux.com${path}`));

      expect(response.headers.get("x-middleware-rewrite")).toBeNull();
      expect(response.headers.get("location")).toBeNull();
    }
  });

  test("caches both immutable image routes", () => {
    expect(defaultImageDynamic).toBe("force-static");
    expect(localizedImageDynamic).toBe("force-static");
  });

  for (const locale of routing.locales) {
    test(
      `renders the ${locale} image response body`,
      async () => {
        const response = await renderLocaleOpenGraphImage(locale);
        const body = new Uint8Array(await response.arrayBuffer());

        expect(response.status).toBe(200);
        expect(response.headers.get("content-type")).toBe("image/png");
        expect([...body.slice(0, 8)]).toEqual([
          137, 80, 78, 71, 13, 10, 26, 10,
        ]);

        const { data } = await sharp(body)
          .extract({ left: 280, top: 1080, width: 1500, height: 150 })
          .removeAlpha()
          .raw()
          .toBuffer({ resolveWithObject: true });
        let visibleTaglinePixels = 0;
        for (let offset = 0; offset < data.length; offset += 3) {
          if (
            data[offset] > 140 &&
            data[offset + 1] > 140 &&
            data[offset + 2] > 140
          ) {
            visibleTaglinePixels += 1;
          }
        }
        expect(visibleTaglinePixels).toBeGreaterThan(5_000);
      },
    );
  }

  for (const locale of routing.locales) {
    test(`bundled fonts cover every ${locale} tagline code point`, async () => {
      const localeFont = openGraphLocaleFonts[locale];
      const filenames = [
        openGraphTaglineFallbackFont,
        ...(localeFont ? [localeFont.filename] : []),
      ];
      const fonts = await Promise.all(
        filenames.map(async (filename) =>
          readFile(
            join(
              process.cwd(),
              "app",
              "lib",
              "open-graph-fonts",
              filename,
            ),
          ),
        ),
      );
      const missingCharacters = [...openGraphImageTagline(locale)].filter(
        (character) =>
          !/^\s$/u.test(character) &&
          !fonts.some((font) =>
            fontSupportsCodePoint(font, character.codePointAt(0)!),
          ),
      );

      expect(missingCharacters).toEqual([]);
    });
  }

  test("insets the screenshot from the card edges", async () => {
    const response = await renderLocaleOpenGraphImage("en");
    const body = new Uint8Array(await response.arrayBuffer());
    const { data } = await sharp(body)
      .extract({ left: 16, top: 16, width: 32, height: 32 })
      .removeAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });
    let nonBackgroundPixels = 0;
    for (let offset = 0; offset < data.length; offset += 3) {
      if (
        Math.abs(data[offset] - 10) > 2 ||
        Math.abs(data[offset + 1] - 10) > 2 ||
        Math.abs(data[offset + 2] - 10) > 2
      ) {
        nonBackgroundPixels += 1;
      }
    }

    expect(nonBackgroundPixels).toBe(0);
  });

  test("keeps the README hero synchronized with the landing screenshot", async () => {
    const [landingScreenshot, readmeScreenshot] = await Promise.all([
      readFile(
        join(
          process.cwd(),
          "app",
          "[locale]",
          "(landing)",
          "assets",
          "landing-image.png",
        ),
      ),
      readFile(
        join(process.cwd(), "..", "docs", "assets", "main-first-image.png"),
      ),
    ]);

    expect(readmeScreenshot.equals(landingScreenshot)).toBe(true);
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
