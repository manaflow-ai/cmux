import { cacheLife } from "next/cache";

/**
 * The public-domain art cmux offers as window backgrounds (cmux-next, cx-t2x.8). The
 * collection's source of truth is art/manifest.json on feat-cmux-next; its publish workflow
 * serves it here with each work's image and thumbnail URL.
 */
export const ART_MANIFEST_URL = "https://files.cmux.com/cmux-art/manifest.json";
const ART_ORIGIN = "https://files.cmux.com/cmux-art/";
const ART_MANIFEST_TIMEOUT_MS = 10_000;

export const artCollections = ["darkArt", "museumIcons", "calm", "dore"] as const;
export type ArtCollection = (typeof artCollections)[number];

export type ArtWork = {
  id: string;
  title: string;
  titles: Record<string, string>;
  artist: string;
  year: string;
  museum: string;
  collection: ArtCollection;
  source: string;
  image: string;
  thumbnail: string;
};

/** The manifest's title locales, by site locale where they differ. */
const manifestLocale: Record<string, string> = { "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", no: "nb" };

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function artURL(value: unknown, origin: string): string | null {
  const url = text(value);
  return url?.startsWith(origin) ? url : null;
}

function parseWork(value: unknown): ArtWork | null {
  if (typeof value !== "object" || value === null) return null;
  const work = value as Record<string, unknown>;
  const id = text(work.id);
  const title = text(work.title);
  const artist = text(work.artist);
  const collection = artCollections.find((name) => name === work.collection);
  const image = artURL(work.image, ART_ORIGIN);
  const thumbnail = artURL(work.thumbnail, ART_ORIGIN);
  const source = artURL(work.source, "https://commons.wikimedia.org/");
  if (!id || !title || !artist || !collection || !image || !thumbnail || !source) return null;
  const titles: Record<string, string> = {};
  if (typeof work.titles === "object" && work.titles !== null) {
    for (const [locale, localized] of Object.entries(work.titles)) {
      const value = text(localized);
      if (value) titles[locale] = value;
    }
  }
  return {
    id,
    title,
    titles,
    artist,
    year: text(work.year) ?? "",
    museum: text(work.museum) ?? "",
    collection,
    source,
    image,
    thumbnail,
  };
}

/**
 * The works a published manifest lists, in manifest order. A work missing a field the page
 * shows, or pointing anywhere but files.cmux.com and Wikimedia Commons, is left out.
 */
export function parseArtManifest(json: unknown): ArtWork[] {
  const works = (json as { works?: unknown } | null)?.works;
  if (!Array.isArray(works)) throw new Error("the art manifest lists no works");
  return works.map(parseWork).filter((work): work is ArtWork => work !== null);
}

export async function loadArtWorks(): Promise<ArtWork[]> {
  "use cache";
  cacheLife("hours");
  const response = await fetch(ART_MANIFEST_URL, { signal: AbortSignal.timeout(ART_MANIFEST_TIMEOUT_MS) });
  if (!response.ok) throw new Error(`the art manifest returned HTTP ${response.status}`);
  return parseArtManifest(await response.json());
}

/** The work's title in `locale`, or its English title. */
export function localizedArtTitle(work: ArtWork, locale: string): string {
  return work.titles[manifestLocale[locale] ?? locale] ?? work.title;
}
