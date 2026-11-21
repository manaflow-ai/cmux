import type { MetadataRoute } from "next";
import type { Listing } from "./registry";
import { SITE, authorPath, listingUrl } from "./refs";

type Entry = MetadataRoute.Sitemap[number];

/**
 * Sitemap entries for the extension and setup pages. They are English content
 * with one URL each (other locales canonicalize to it), so they carry no
 * hreflang alternates. The index pages are listed even when the registry
 * cannot be read; listing and author pages only when it can.
 */
export function extensionSitemapEntries(extensions: readonly Listing[] | null, setups: readonly Listing[] | null): Entry[] {
  const listings = [...(extensions ?? []), ...(setups ?? [])];
  const newest = (items: readonly Listing[]) =>
    items.map((listing) => listing.reviewedAt ?? listing.updatedAt).filter((date): date is string => Boolean(date)).sort().at(-1);
  const entries: Entry[] = [
    { url: `${SITE}/extensions`, lastModified: newest(extensions ?? []) ?? "2026-11-17", changeFrequency: "daily", priority: 0.8 },
    { url: `${SITE}/setups`, lastModified: newest(setups ?? []) ?? "2026-11-17", changeFrequency: "daily", priority: 0.7 },
  ];
  const authors = new Map<string, Listing[]>();
  for (const listing of listings) {
    const date = listing.reviewedAt ?? listing.updatedAt;
    entries.push({
      url: listingUrl(listing, listing.kind),
      ...(date ? { lastModified: date } : {}),
      changeFrequency: "weekly",
      priority: 0.6,
    });
    // Only GitHub owners have author pages (refs.ts authorPath).
    const path = authorPath(listing);
    if (!path) continue;
    const key = path.toLowerCase();
    const group = authors.get(key);
    if (group) group.push(listing);
    else authors.set(key, [listing]);
  }
  for (const owned of authors.values()) {
    const date = newest(owned);
    entries.push({
      url: `${SITE}${authorPath(owned[0]!)}`,
      ...(date ? { lastModified: date } : {}),
      changeFrequency: "weekly",
      priority: 0.4,
    });
  }
  return entries;
}
