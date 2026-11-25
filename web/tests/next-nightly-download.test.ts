import { describe, expect, mock, test } from "bun:test";

import {
  CMUX_NEXT_DOWNLOAD_PATH,
  CMUX_NEXT_NIGHTLY_DMG_URL,
  CMUX_NEXT_NIGHTLY_FEED_URL,
} from "../app/lib/nightly-downloads";
import {
  NextNightlyDownloadError,
  resolveNextNightlyDownload,
} from "../app/lib/next-nightly-download";
import { handleNextNightlyDownloadRequest } from "../app/api/download/next/route";

const R2 = "https://files-next.cmux.com/nightly-next/";

function item(build: string, url: string, deltaFrom?: string): string {
  const deltas = deltaFrom
    ? `<sparkle:deltas>
                <enclosure url="${R2}cmux-nightly-next-macos-arm64-${build}-${deltaFrom}.delta" sparkle:deltaFrom="${deltaFrom}" length="5" type="application/octet-stream" sparkle:edSignature="d=="/>
            </sparkle:deltas>`
    : "";
  return `<item>
            <sparkle:channel>cmux-next</sparkle:channel>
            <title>1.0.0-nightly.${build}</title>
            <sparkle:version>${build}</sparkle:version>
            ${deltas}
            <enclosure url="${url}" length="239117941" type="application/octet-stream" sparkle:edSignature="s=="/>
        </item>`;
}

function feed(...items: string[]): string {
  return `<?xml version="1.0" encoding="utf-8"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>cmux NIGHTLY</title>${items.join("")}</channel></rss>`;
}

function feedFetch(body: string, status = 200) {
  return mock(async (input: RequestInfo | URL) => {
    expect(String(input)).toBe(CMUX_NEXT_NIGHTLY_FEED_URL);
    return new Response(body, { status });
  }) as unknown as typeof fetch & ReturnType<typeof mock>;
}

describe("cmux NEXT download follows the live update feed", () => {
  test("links point at the feed-backed route, not the separately published rolling asset", () => {
    expect(CMUX_NEXT_DOWNLOAD_PATH).toBe("/api/download/next");
    expect(CMUX_NEXT_NIGHTLY_FEED_URL).toBe(
      "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
    );
  });

  test("resolves the newest build's full DMG, even when the feed lists an older build first", async () => {
    const fetchMock = feedFetch(
      feed(
        item("4450292330201", `${R2}cmux-nightly-next-macos-arm64-4450292330201.dmg`),
        item("4469962314401", `${R2}cmux-nightly-next-macos-arm64-4469962314401.dmg`, "4450292330201"),
      ),
    );
    const resolution = await resolveNextNightlyDownload({ fetch: fetchMock });
    expect(resolution).toEqual({
      build: "4469962314401",
      url: `${R2}cmux-nightly-next-macos-arm64-4469962314401.dmg`,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("accepts a build the feed still serves from the nightly-next GitHub release", async () => {
    const github =
      "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos-arm64-4469962314401.dmg";
    const resolution = await resolveNextNightlyDownload({
      fetch: feedFetch(feed(item("4469962314401", github))),
    });
    expect(resolution.url).toBe(github);
  });

  test("refuses a newest item whose DMG is outside the published origins or names another build", async () => {
    for (const url of [
      "https://example.com/cmux-nightly-next-macos-arm64-4469962314401.dmg",
      `${R2}cmux-nightly-next-macos-arm64-4450292330201.dmg`,
      `${R2}stable/cmux-nightly-next-macos-arm64-4469962314401.dmg`,
      `${R2}cmux-nightly-next-macos-arm64-4469962314401.dmg?x=1`,
    ]) {
      await expect(
        resolveNextNightlyDownload({ fetch: feedFetch(feed(item("4469962314401", url))) }),
      ).rejects.toEqual(new NextNightlyDownloadError("invalid_feed"));
    }
  });

  test("refuses an empty feed and an unreachable feed", async () => {
    await expect(
      resolveNextNightlyDownload({ fetch: feedFetch(feed()) }),
    ).rejects.toEqual(new NextNightlyDownloadError("invalid_feed"));
    await expect(
      resolveNextNightlyDownload({ fetch: feedFetch("nope", 503) }),
    ).rejects.toEqual(new NextNightlyDownloadError("upstream_unavailable"));
  });

  test("the route redirects to the feed's newest DMG with a short shared cache", async () => {
    const newest = `${R2}cmux-nightly-next-macos-arm64-4469962314401.dmg`;
    const response = await handleNextNightlyDownloadRequest({
      fetch: feedFetch(feed(item("4469962314401", newest))),
    });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(newest);
    expect(response.headers.get("x-cmux-build")).toBe("4469962314401");
    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=0, s-maxage=15, stale-while-revalidate=45",
    );
  });

  test("the route still downloads cmux NEXT when the feed cannot be read", async () => {
    const response = await handleNextNightlyDownloadRequest({
      fetch: mock(async () => {
        throw new Error("offline");
      }) as unknown as typeof fetch,
    });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(CMUX_NEXT_NIGHTLY_DMG_URL);
    expect(response.headers.get("cache-control")).toBe("no-store");
  });
});
