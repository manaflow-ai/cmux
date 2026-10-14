import type { MetadataRoute } from "next";
import { cacheLife } from "next/cache";
import { isDocsPathname, releaseDocsOrigin } from "./docs-channel";

const RELEASE_SITEMAP_TIMEOUT_MS = 10_000;

function isDocsUrl(url: string): boolean {
  try {
    return isDocsPathname(new URL(url).pathname);
  } catch {
    return false;
  }
}

function decodeXmlText(value: string): string {
  return value
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", "\"")
    .replaceAll("&apos;", "'")
    .replaceAll("&amp;", "&");
}

/**
 * The docs URLs a sitemap lists. Throws when there are none, because a
 * release zone that serves docs always lists some, so an empty set means the
 * response was not that zone's sitemap.
 */
export function docsUrlsFromSitemapXml(xml: string): string[] {
  const urls = new Set<string>();
  for (const match of xml.matchAll(/<loc>([^<]+)<\/loc>/gu)) {
    const url = decodeXmlText(match[1]!.trim());
    if (isDocsUrl(url)) urls.add(url);
  }
  if (urls.size === 0) throw new Error("the release docs sitemap lists no docs URLs");
  return [...urls].sort();
}

/**
 * Drops docs entries, and docs alternates, that the release docs zone does
 * not serve. cmux.com/docs is rewritten to that zone, which is built from the
 * latest release tag, so docs added on main return 404 there until the next
 * release. Non-docs entries are served by this deployment and pass through.
 */
export function keepServedDocsEntries(
  entries: MetadataRoute.Sitemap,
  servedDocsUrls: ReadonlySet<string>,
): MetadataRoute.Sitemap {
  const isServed = (url: string) => !isDocsUrl(url) || servedDocsUrls.has(url);
  const kept: MetadataRoute.Sitemap = [];
  for (const entry of entries) {
    if (!isServed(entry.url)) continue;
    const languages = entry.alternates?.languages;
    if (!languages) {
      kept.push(entry);
      continue;
    }
    const servedLanguages = Object.fromEntries(
      Object.entries(languages).filter(
        ([, url]) => typeof url === "string" && isServed(url),
      ),
    );
    kept.push({ ...entry, alternates: { ...entry.alternates, languages: servedLanguages } });
  }
  return kept;
}

/**
 * The docs URLs the release docs zone serves, read from its own sitemap. That
 * zone generates the sitemap from the routes it was built with, so it is the
 * one record of what cmux.com/docs serves. Failures throw and are not cached.
 */
export async function releaseDocsUrls(): Promise<string[]> {
  "use cache";
  cacheLife("hours");

  const response = await fetch(`${releaseDocsOrigin()}/sitemap.xml`, {
    signal: AbortSignal.timeout(RELEASE_SITEMAP_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`the release docs sitemap returned HTTP ${response.status}`);
  }
  return docsUrlsFromSitemapXml(await response.text());
}
