import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import { renderToStaticMarkup } from "react-dom/server";
import {
  changelogPath,
  changelogVersionDescription,
  changelogVersionPath,
  localizedChangelogPath,
  parseChangelog,
  readChangelog,
} from "../app/lib/changelog";
import sitemap from "../app/sitemap";
import middleware from "../proxy";
import { ChangelogRelease } from "../app/[locale]/(landing)/docs/changelog/changelog-release";
import { generateStaticParams } from "../app/[locale]/(landing)/docs/changelog/[version]/page";

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
        versionHref={localizedChangelogPath("ja", release.version)}
        first
      />,
    );
    expect(html).toContain('href="/ja/docs/changelog/1.2.3"');
    expect(html).toContain('dateTime="2026-08-03"');
    expect(html).toContain("2026年8月3日");
    expect(html).toContain("cmux example");
  });

  test("pre-renders a route for every version in the source changelog", () => {
    const versions = readChangelog().map((release) => release.version);

    expect(generateStaticParams()).toEqual(
      versions.map((version) => ({ version })),
    );
    expect(versions.length).toBeGreaterThan(80);
    expect(versions[0]).toMatch(/^\d+\.\d+\.\d+$/);
  });

  test("emits unique release summaries without Markdown URLs", () => {
    const release = readChangelog()[0];
    const description = changelogVersionDescription(release);

    expect(description.startsWith(`cmux ${release.version}:`)).toBe(true);
    expect(description).not.toContain("https://");
    expect(description).not.toContain("[");
    expect(description.length).toBeLessThanOrEqual(160);
  });

  test("publishes every version and locale through the sitemap", () => {
    const releases = readChangelog();
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
});
