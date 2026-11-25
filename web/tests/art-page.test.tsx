import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createTranslator } from "use-intl/core";
import { sitemapEntries as sitemap } from "../app/sitemap";
import { resolveAgentPageVariant } from "../app/lib/agent-page-paths";
import { locales, type Locale } from "../i18n/routing";
import enMessages from "../messages/en.json";

type Messages = typeof enMessages;
const messagesByLocale = {} as Record<Locale, Messages>;
for (const locale of locales) {
  messagesByLocale[locale] = (await import(`../messages/${locale}.json`)).default as Messages;
}

mock.module("next-intl/server", () => ({
  getTranslations: async (options: { locale: Locale; namespace: string }) =>
    createTranslator({
      locale: options.locale,
      messages: messagesByLocale[options.locale],
      namespace: options.namespace as never,
    }),
}));

const { parseArtManifest } = await import("../app/[locale]/(landing)/art/art-manifest");
const { ArtGallery } = await import("../app/[locale]/(landing)/art/art-gallery");

const origin = "https://files.cmux.com/cmux-art/";
function work(id: string, collection: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    title: `Title ${id}`,
    titles: { ja: `題 ${id}`, "zh-Hans": `标题 ${id}`, nb: `Tittel ${id}` },
    artist: `Artist ${id}`,
    year: "1889",
    museum: "Museum",
    collection,
    source: `https://commons.wikimedia.org/wiki/File:${id}.jpg`,
    image: `${origin}${"a".repeat(64)}.avif`,
    thumbnail: `${origin}${"b".repeat(64)}.avif`,
    ...overrides,
  };
}

const manifest = {
  version: 1,
  works: [
    work("starry-night", "darkArt"),
    work("great-wave", "museumIcons"),
    work("water-lilies", "calm"),
    work("dore-raven", "dore"),
    work("elsewhere", "calm", { thumbnail: "https://example.com/x.avif" }),
    work("bad-source", "calm", { source: "javascript:alert(1)" }),
    work("no-collection", "figureDrawings"),
  ],
};

async function render(locale: Locale, works = parseArtManifest(manifest)) {
  return renderToStaticMarkup(await ArtGallery({ locale, works }));
}

describe("cmux.com/art", () => {
  test("shows each published work under its collection, in picker order", async () => {
    const html = await render("en");
    const order = ["Dark Art", "Museum Icons", "Calm", "Doré"].map((name) => html.indexOf(`>${name}</h2>`));
    expect(order.every((index) => index >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
    expect(html).toContain("Title starry-night");
    expect(html).toContain("Artist starry-night · 1889");
    expect(html).toContain(`src="${origin}${"b".repeat(64)}.avif"`);
    expect(html).toContain('href="https://commons.wikimedia.org/wiki/File:starry-night.jpg"');
  });

  test("leaves out works hosted elsewhere, with a non-Commons source or an unknown collection", async () => {
    const html = await render("en");
    for (const id of ["elsewhere", "bad-source", "no-collection"]) {
      expect(html).not.toContain(`Title ${id}`);
    }
    expect(html).not.toContain("example.com");
    expect(html).not.toContain("javascript:");
  });

  test("uses the work's title in the reader's language", async () => {
    expect(await render("ja")).toContain("題 starry-night");
    expect(await render("zh-CN")).toContain("标题 starry-night");
    expect(await render("no")).toContain("Tittel starry-night");
    expect(await render("de")).toContain("Title starry-night");
  });

  test("says the collection is unavailable when the manifest could not load", async () => {
    const html = await render("en", null as never);
    expect(html).toContain(enMessages.art.unavailable);
  });

  test("every locale names the page and its collections", () => {
    const missing = locales.filter((locale) => {
      const { art, footer } = messagesByLocale[locale];
      const collections = Object.keys(art?.collections ?? {}).sort().join(",");
      return !art?.title || !footer.art || collections !== "calm,darkArt,dore,museumIcons";
    });
    expect(missing).toEqual([]);
  });

  test("is in the sitemap with an agent-readable variant", () => {
    expect(sitemap().some((entry) => new URL(entry.url).pathname.endsWith("/art"))).toBe(true);
    expect(resolveAgentPageVariant("/art.md")).not.toBeNull();
  });
});
