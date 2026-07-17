import type { MetadataRoute } from "next";

export const indexNowKey = "82cc8125a8624a4db9e07502db0b7d46";
export const indexNowEndpoint = "https://api.indexnow.org/indexnow";
export const indexNowLookbackHours = 48;

type SitemapEntry = MetadataRoute.Sitemap[number];

export function recentlyModifiedUrls(
  entries: readonly SitemapEntry[],
  now: Date,
  lookbackHours = indexNowLookbackHours,
): string[] {
  const latest = now.getTime();
  const earliest = latest - lookbackHours * 60 * 60 * 1000;

  return entries.flatMap((entry) => {
    if (!entry.lastModified) return [];
    const modified = new Date(entry.lastModified).getTime();
    if (!Number.isFinite(modified) || modified < earliest || modified > latest) {
      return [];
    }
    return [String(entry.url)];
  });
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
): Promise<number> {
  if (urls.length === 0) return 0;
  if (urls.length > 10_000) {
    throw new Error("IndexNow accepts at most 10,000 URLs per request");
  }

  const response = await fetcher(indexNowEndpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(indexNowPayload(urls)),
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 240);
    throw new Error(`IndexNow rejected the update (${response.status}): ${detail}`);
  }

  return response.status;
}
