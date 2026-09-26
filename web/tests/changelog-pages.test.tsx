import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import { renderToStaticMarkup } from "react-dom/server";
import { createTranslator } from "use-intl/core";
import {
  changelogPath,
  changelogStaticVersionCount,
  changelogVersionDescription,
  changelogVersionPath,
  changelogVersionsForPrerender,
  localizedChangelogPath,
  ChangelogStore,
  parseChangelog,
} from "../app/lib/changelog";
import { changelogStore } from "../app/lib/changelog-store";
import {
  docsPagerAdjacentItems,
  docsPagerItemIndex,
} from "../app/lib/docs-pager-path";
import sitemap from "../app/sitemap";
import middleware from "../proxy";
import { locales } from "../i18n/routing";
import { ChangelogRelease } from "../app/[locale]/(landing)/docs/changelog/changelog-release";
import { generateStaticParams } from "../app/[locale]/(landing)/docs/changelog/[version]/page";
import {
  changelogMedia,
  type VersionMedia,
} from "../app/[locale]/(landing)/docs/changelog/changelog-media";
import { ChangelogVideoView } from "../app/[locale]/(landing)/docs/changelog/changelog-video";
import { existsSync, statSync } from "fs";
import path from "path";

type Messages = typeof import("../messages/en.json");

describe("per-version changelog pages", () => {
  test("parses each release into independently renderable content", () => {
    const [release] = parseChangelog(`
# Changelog

## [1.2.3] - 2026-08-03

Release intro.

### Added
- Added \`cmux example\` ([#123](https://github.com/manaflow-ai/cmux/pull/123))
`);

    expect(release).toEqual({
      version: "1.2.3",
      date: "2026-08-03",
      intro: "Release intro.",
      sections: [
        {
          heading: "Added",
          items: [
            "Added `cmux example` ([#123](https://github.com/manaflow-ai/cmux/pull/123))",
          ],
        },
      ],
    });

    const html = renderToStaticMarkup(
      <ChangelogRelease
        release={release}
        locale="ja"
        sectionLabels={{
          added: "追加",
          changed: "変更",
          fixed: "修正",
          removed: "削除",
          contributors: "コントリビューター",
          tryIt: "試してみる",
        }}
        versionHref={localizedChangelogPath("ja", release.version)}
        first
      />,
    );
    expect(html).toContain('href="/ja/docs/changelog/1.2.3"');
    expect(html).toContain('dateTime="2026-08-03"');
    expect(html).toContain("2026年8月3日");
    expect(html).toContain("追加");
    expect(html).toContain("cmux example");
  });

  test("refreshes and isolates injected changelog stores", () => {
    let fingerprint = "first";
    let reads = 0;
    let markdown = "## [1.0.0] - 2026-08-03\n\n### Added\n- First";
    const store = new ChangelogStore({
      fingerprint: () => fingerprint,
      read: () => {
        reads += 1;
        return markdown;
      },
    });

    expect(store.findVersion("1.0.0")?.version).toBe("1.0.0");
    expect(store.versions()[0]?.version).toBe("1.0.0");
    expect(reads).toBe(1);

    markdown = "## [2.0.0] - 2026-08-04\n\n### Changed\n- Second";
    expect(store.versions()[0]?.version).toBe("1.0.0");
    fingerprint = "second";
    expect(store.versions()[0]?.version).toBe("2.0.0");
    expect(reads).toBe(2);

    const isolatedStore = new ChangelogStore({
      fingerprint: () => "isolated",
      read: () => "## [9.0.0] - 2026-08-05",
    });
    expect(isolatedStore.versions()[0]?.version).toBe("9.0.0");
    expect(store.versions()[0]?.version).toBe("2.0.0");
  });

  test("pre-renders recent versions and keeps historical routes available", () => {
    const versions = changelogStore
      .versions()
      .map((release) => release.version);
    const expectedStaticVersions = versions.slice(0, changelogStaticVersionCount);

    expect(generateStaticParams()).toEqual(
      expectedStaticVersions.map((version) => ({ version })),
    );
    expect(versions.length).toBeGreaterThan(80);
    expect(expectedStaticVersions.length).toBe(changelogStaticVersionCount);
    expect(changelogVersionsForPrerender(changelogStore.versions())).toHaveLength(
      changelogStaticVersionCount,
    );
    expect(generateStaticParams()).not.toContainEqual({
      version: versions.at(-1),
    });
    expect(versions[0]).toMatch(/^\d+\.\d+\.\d+$/);
  });

  test("uses the exact or deepest docs page for nested release routes", () => {
    const items = [
      { href: "/docs" },
      { href: "/docs/changelog" },
      { href: "/docs/changelog/archive" },
    ];

    expect(docsPagerItemIndex(items, "/docs/changelog")).toBe(1);
    expect(docsPagerItemIndex(items, "/docs/changelog/0.64.22")).toBe(1);
    expect(
      docsPagerItemIndex(items, "/docs/changelog/archive/0.17.0"),
    ).toBe(2);
    expect(docsPagerAdjacentItems(items, "/outside-docs")).toEqual({
      prev: null,
      next: null,
    });
  });

  test("emits unique release summaries without Markdown URLs", () => {
    const release = changelogStore.versions()[0];
    const description = changelogVersionDescription(release);

    expect(description.startsWith(`cmux ${release.version}:`)).toBe(true);
    expect(description).not.toContain("https://");
    expect(description).not.toContain("[");
    expect(description.length).toBeLessThanOrEqual(160);
  });

  test("publishes every version and locale through the sitemap", () => {
    const releases = changelogStore.versions();
    const entries = sitemap();
    const latest = releases[0];
    const indexEntry = entries.find(
      (entry) => entry.url === `https://cmux.com${changelogPath}`,
    );

    expect(indexEntry?.lastModified).toBe(latest.date);

    for (const release of releases) {
      const path = changelogVersionPath(release.version);
      const entry = entries.find(
        (candidate) => candidate.url === `https://cmux.com${path}`,
      );
      expect(entry?.lastModified).toBe(release.date);
      expect(entry?.changeFrequency).toBe("never");
      expect(entry?.alternates?.languages?.ja).toBe(
        `https://cmux.com/ja${path}`,
      );
      expect(
        entries.some(
          (candidate) => candidate.url === `https://cmux.com/ja${path}`,
        ),
      ).toBe(true);
    }
  });

  test("localizes dotted canonical paths and redirects the short alias", () => {
    const previousDocsChannel = process.env.CMUX_DOCS_CHANNEL;
    process.env.CMUX_DOCS_CHANNEL = "release";

    try {
      const canonical = middleware(
        new NextRequest("https://cmux.com/docs/changelog/0.64.22", {
          headers: { "accept-language": "en" },
        }),
      );
      expect(canonical.status).toBe(200);
      expect(canonical.headers.get("x-middleware-rewrite")).toBe(
        "https://cmux.com/en/docs/changelog/0.64.22",
      );

      const alias = middleware(
        new NextRequest("https://cmux.com/changelog/0.64.22"),
      );
      expect(alias.status).toBe(307);
      expect(alias.headers.get("location")).toBe(
        "https://cmux.com/docs/changelog/0.64.22",
      );
    } finally {
      if (previousDocsChannel === undefined) {
        delete process.env.CMUX_DOCS_CHANNEL;
      } else {
        process.env.CMUX_DOCS_CHANNEL = previousDocsChannel;
      }
    }
  });

  test("provides changelog section labels for every supported locale", async () => {
    for (const locale of locales) {
      // The locale is dynamic so this test follows the routing registry.
      const messages = (
        await import(`../messages/${locale}.json`)
      ).default as Messages;
      const labels = messages.docs.changelog.sections;
      const t = createTranslator({
        locale,
        messages,
        namespace: "docs.changelog",
      });

      expect(Object.keys(labels).sort()).toEqual([
        "added",
        "changed",
        "contributors",
        "fixed",
        "removed",
      ]);
      for (const label of Object.values(labels)) {
        expect(label.trim().length).toBeGreaterThan(0);
      }
      expect(t("tryIt").trim().length).toBeGreaterThan(0);
      expect(t("versionTitle", { version: "1.2.3" })).toContain("1.2.3");
      expect(t("releaseNavLabel", { version: "1.2.3" })).toContain("1.2.3");
    }
  });
});

const englishLabels = {
  added: "Added",
  changed: "Changed",
  fixed: "Fixed",
  removed: "Removed",
  contributors: "Contributors",
  tryIt: "Try it",
};

const sampleRelease = {
  version: "9.9.9",
  date: "2026-09-20",
  intro: "",
  sections: [{ heading: "Added", items: ["Something"] }],
};

function renderRelease(media: VersionMedia) {
  return renderToStaticMarkup(
    <ChangelogRelease
      release={sampleRelease}
      locale="en"
      media={media}
      sectionLabels={englishLabels}
      first
    />,
  );
}

function count(html: string, needle: string) {
  return html.split(needle).length - 1;
}

describe("changelog patch notes cards", () => {
  test("renders a Try it row only for features that have one", () => {
    const html = renderRelease({
      title: "Sample",
      features: [
        {
          title: "Remote",
          description: "Connect anywhere.",
          tryIt: "Run `cmux ssh user@host` to connect.",
        },
        { title: "Quiet", description: "Nothing to try." },
      ],
    });

    expect(count(html, "data-changelog-feature")).toBe(2);
    expect(count(html, "data-changelog-try-it")).toBe(1);
    expect(html).toContain("Try it");
    expect(html).toContain("<code>cmux ssh user@host</code>");
  });

  test("text-only cards pair up and a trailing card spans the row", () => {
    const html = renderRelease({
      title: "Sample",
      features: [
        { title: "A", description: "a" },
        { title: "B", description: "b" },
        { title: "C", description: "c" },
      ],
    });
    expect(count(html, "sm:col-span-2")).toBe(1);
    expect(html.indexOf("sm:col-span-2")).toBeGreaterThan(
      html.indexOf(">B</h3>"),
    );
  });

  test("server markup shows the still clip without autoplay", () => {
    const html = renderRelease({
      title: "Sample",
      features: [
        {
          title: "Clip",
          description: "Moves.",
          video: {
            src: "/changelog/9.9.9/clip.mp4",
            webm: "/changelog/9.9.9/clip.webm",
            poster: "/changelog/0.61.0-open-with.png",
          },
        },
      ],
    });

    expect(html).toContain("<video");
    expect(html).toContain('poster="/changelog/0.61.0-open-with.png"');
    expect(html).not.toContain("autoPlay");
    expect(html).not.toMatch(/<video[^>]*\sloop/);
    expect(html).not.toContain("controls");
    expect(html).toContain("sm:col-span-2");
  });

  test("clips loop silently without controls when motion is allowed", () => {
    const video = {
      src: "/changelog/9.9.9/clip.mp4",
      webm: "/changelog/9.9.9/clip.webm",
      poster: "/changelog/9.9.9/clip.png",
    };
    const moving = renderToStaticMarkup(
      <ChangelogVideoView
        video={video}
        label="Clip"
        width={1600}
        height={900}
        reducedMotion={false}
      />,
    );
    expect(moving).toContain("autoPlay");
    expect(moving).toMatch(/<video[^>]*\sloop/);
    expect(moving).toContain("playsInline");
    expect(moving).not.toContain("controls");
    expect(moving).toContain("aspect-ratio:1600 / 900");
    expect(moving.indexOf("video/webm")).toBeLessThan(
      moving.indexOf("video/mp4"),
    );

    const still = renderToStaticMarkup(
      <ChangelogVideoView video={video} label="Clip" reducedMotion />,
    );
    expect(still).not.toContain("autoPlay");
    expect(still).not.toMatch(/<video[^>]*\sloop/);
    expect(still).toContain('poster="/changelog/9.9.9/clip.png"');
    expect(still).toContain('preload="none"');
  });

  test("the latest documented release says how to try each feature", () => {
    for (const feature of changelogMedia["0.64.25"].features ?? []) {
      expect(feature.tryIt?.trim().length ?? 0).toBeGreaterThan(0);
    }
  });

  test("every referenced changelog media file exists and clips stay small", () => {
    const publicPath = (file: string) =>
      path.join(process.cwd(), "public", file);
    for (const media of Object.values(changelogMedia)) {
      const files = [media.hero];
      for (const feature of media.features ?? []) {
        files.push(feature.image, feature.video?.poster);
        for (const clip of [feature.video?.src, feature.video?.webm]) {
          if (!clip) continue;
          expect(existsSync(publicPath(clip))).toBe(true);
          expect(statSync(publicPath(clip)).size).toBeLessThanOrEqual(
            2 * 1024 * 1024,
          );
        }
      }
      for (const file of files) {
        if (file) expect(existsSync(publicPath(file))).toBe(true);
      }
    }
  });
});
