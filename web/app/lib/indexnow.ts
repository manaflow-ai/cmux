import type { MetadataRoute } from "next";

export const indexNowKey = "82cc8125a8624a4db9e07502db0b7d46";
export const indexNowEndpoint = "https://api.indexnow.org/indexnow";
export const indexNowLookbackHours = 48;
export const indexNowTimeoutMs = 10_000;

type SitemapEntry = MetadataRoute.Sitemap[number];

export function recentlyModifiedUrls(
  entries: readonly SitemapEntry[],
  now: Date,
  lookbackHours = indexNowLookbackHours,
): string[] {
  const latest = now.getTime();
  const modifiedEntries: Array<{ modified: number; url: string }> = [];
  let newestModification = -Infinity;

  for (const entry of entries) {
    if (!entry.lastModified) continue;
    const modified = new Date(entry.lastModified).getTime();
    if (!Number.isFinite(modified) || modified > latest) continue;
    newestModification = Math.max(newestModification, modified);
    modifiedEntries.push({ modified, url: String(entry.url) });
  }
  // This selection runs once after each production deployment. Sitemap dates
  // describe content, so anchoring to the newest entry preserves delayed releases.
  const earliest = newestModification - lookbackHours * 60 * 60 * 1000;

  const urls: string[] = [];
  for (const entry of modifiedEntries) {
    if (entry.modified >= earliest) urls.push(entry.url);
  }
  return urls;
}

export function indexNowPayload(urls: readonly string[]) {
  return {
    host: "cmux.com",
    key: indexNowKey,
    keyLocation: `https://cmux.com/${indexNowKey}.txt`,
    urlList: [...urls],
  };
}

export async function submitIndexNowUrls(
  urls: readonly string[],
  fetcher: typeof fetch = fetch,
  timeoutMs = indexNowTimeoutMs,
): Promise<number> {
  if (urls.length === 0) return 0;
  if (urls.length > 10_000) {
    throw new Error("IndexNow accepts at most 10,000 URLs per request");
  }

  const response = await fetcher(indexNowEndpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(indexNowPayload(urls)),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 240);
    throw new Error(`IndexNow rejected the update (${response.status}): ${detail}`);
  }

  return response.status;
}
