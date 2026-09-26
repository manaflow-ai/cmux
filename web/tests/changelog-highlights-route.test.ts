import { describe, expect, test } from "bun:test";

import { changelogMedia } from "../app/[locale]/(landing)/docs/changelog/changelog-media";

const { GET, buildHighlights } = await import("../app/api/changelog/highlights/route");

describe("changelog highlights route", () => {
  test("serves every changelog-media version, newest first", async () => {
    const response = await GET(new Request("https://cmux.test/api/changelog/highlights"));
    expect(response.status).toBe(200);
    const payload = (await response.json()) as ReturnType<typeof buildHighlights>;
    expect(payload.releases.length).toBe(Object.keys(changelogMedia).length);
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

  test("makes media absolute and passes optional tryIt and video through", () => {
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
            video: "/changelog/feature.mp4",
          } as never,
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
    expect(ten.features[1]).toEqual({ title: "Plain", description: "No media." });
    expect(nine.features).toEqual([]);
  });
});
