import { describe, expect, test } from "bun:test";

import { changelogMedia } from "../app/[locale]/(landing)/docs/changelog/changelog-media";

const { GET, buildHighlights, MAX_RELEASES } = await import(
  "../app/api/changelog/highlights/route"
);

describe("changelog highlights route", () => {
  test("serves the newest changelog-media versions, newest first", async () => {
    const response = await GET(new Request("https://cmux.test/api/changelog/highlights"));
    expect(response.status).toBe(200);
    const payload = (await response.json()) as ReturnType<typeof buildHighlights>;
    // Only shipped versions are announced; placeholder keys such as
    // "Unreleased" (renamed at release cut) stay off the app's recap.
    const shipped = Object.keys(changelogMedia).filter((key) => /^\d+(\.\d+)*$/.test(key));
    expect(payload.releases.length).toBe(Math.min(shipped.length, MAX_RELEASES));
    expect(payload.releases.map((release) => release.version)).not.toContain("Unreleased");
    const versions = payload.releases.map((release) => release.version);
    const sorted = [...versions].sort((a, b) => {
      const left = a.split(".").map(Number);
      const right = b.split(".").map(Number);
      for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
        const difference = (right[index] ?? 0) - (left[index] ?? 0);
        if (difference !== 0) return difference;
      }
      return 0;
    });
    expect(versions).toEqual(sorted);
  });

  test("caps the payload at the newest MAX_RELEASES entries", () => {
    const media: Record<string, { title: string }> = {};
    for (let index = 0; index < MAX_RELEASES + 5; index += 1) {
      media[`0.${index}.0`] = { title: `Release ${index}` };
    }
    const payload = buildHighlights(media);
    expect(payload.releases.length).toBe(MAX_RELEASES);
    // The cap drops the oldest, never the newest.
    expect(payload.releases[0].version).toBe(`0.${MAX_RELEASES + 4}.0`);
    expect(payload.releases.map((release) => release.version)).not.toContain("0.0.0");
  });

  test("answers a matching ETag with 304", async () => {
    const first = await GET(new Request("https://cmux.test/api/changelog/highlights"));
    const etag = first.headers.get("etag");
    expect(etag).toBeTruthy();
    const second = await GET(
      new Request("https://cmux.test/api/changelog/highlights", {
        headers: { "If-None-Match": etag ?? "" },
      }),
    );
    expect(second.status).toBe(304);
  });

  test("makes media absolute and passes tryIt and the clip's mp4 through", () => {
    const payload = buildHighlights({
      "0.10.0": {
        title: "Ten",
        hero: "/changelog/hero.png",
        features: [
          {
            title: "Feature",
            description: "Does a thing.",
            image: "/changelog/feature.png",
            tryIt: "  Press Cmd+K.  ",
            video: { src: "/changelog/feature.mp4", webm: "/changelog/feature.webm" },
          },
          {
            title: "Clip",
            description: "Poster only.",
            video: { src: "/changelog/clip.mp4", poster: "/changelog/clip.png" },
          },
          { title: "Plain", description: "No media." },
        ],
      },
      "0.9.0": { title: "Nine" },
    });
    expect(payload.releases.map((release) => release.version)).toEqual(["0.10.0", "0.9.0"]);
    const [ten, nine] = payload.releases;
    expect(ten.url).toBe("https://cmux.com/docs/changelog/0.10.0");
    expect(ten.hero).toBe("https://cmux.com/changelog/hero.png");
    expect(ten.features[0]).toEqual({
      title: "Feature",
      description: "Does a thing.",
      tryIt: "Press Cmd+K.",
      image: "https://cmux.com/changelog/feature.png",
      video: "https://cmux.com/changelog/feature.mp4",
    });
    expect(ten.features[1]).toEqual({
      title: "Clip",
      description: "Poster only.",
      image: "https://cmux.com/changelog/clip.png",
      video: "https://cmux.com/changelog/clip.mp4",
    });
    expect(ten.features[2]).toEqual({ title: "Plain", description: "No media." });
    expect(nine.features).toEqual([]);
  });
});
