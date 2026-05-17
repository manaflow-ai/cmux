import { describe, expect, test } from "bun:test";
import {
  nextDocsSearchIndex,
  normalizeDocsSearchResult,
  normalizePagefindUrl,
} from "../app/[locale]/components/docs-search-utils";

describe("docs search utilities", () => {
  test("normalizes Pagefind URLs to app routes", () => {
    expect(normalizePagefindUrl("/docs/getting-started/")).toBe(
      "/docs/getting-started",
    );
    expect(
      normalizePagefindUrl("https://cmux.com/ja/docs/api/index.html#surface"),
    ).toBe("/ja/docs/api#surface");
    expect(normalizePagefindUrl("/docs/configuration/index.html")).toBe(
      "/docs/configuration",
    );
  });

  test("prefers section-level Pagefind matches", () => {
    const result = normalizeDocsSearchResult({
      url: "/docs/configuration/",
      excerpt: "Configure <mark>cmux</mark>.",
      plain_excerpt: "Configure cmux.",
      meta: {
        title: "Configuration",
        section: "Docs",
      },
      sub_results: [
        {
          title: "Configuration",
          url: "/docs/configuration/#title",
          excerpt: "Configure <mark>cmux</mark>.",
          plain_excerpt: "Configure cmux.",
          weighted_locations: [{ balanced_score: 100 }],
        },
        {
          title: "Keyboard shortcuts",
          url: "/docs/configuration/#keyboard-shortcuts",
          excerpt: "Set <mark>shortcuts</mark> in cmux.json.",
          plain_excerpt: "Set shortcuts in cmux.json.",
          weighted_locations: [{ balanced_score: 1000 }],
        },
      ],
    });

    expect(result).toEqual({
      href: "/docs/configuration#keyboard-shortcuts",
      title: "Keyboard shortcuts",
      section: "Docs",
      excerptHtml: "Set <mark>shortcuts</mark> in cmux.json.",
      plainExcerpt: "Set shortcuts in cmux.json.",
    });
  });

  test("uses a strong section match when the title also matches", () => {
    const result = normalizeDocsSearchResult({
      url: "/docs/skills/",
      meta: {
        title: "Skills",
      },
      sub_results: [
        {
          title: "Skills",
          url: "/docs/skills/#title",
          excerpt: "Install and use <mark>skills</mark>.",
          plain_excerpt: "Install and use skills.",
          weighted_locations: [{ balanced_score: 100 }],
        },
        {
          title: "Skill layout",
          url: "/docs/skills/#authoring-title",
          excerpt: "<mark>Skill layout</mark>.",
          plain_excerpt: "Skill layout.",
          weighted_locations: [{ balanced_score: 70 }],
        },
      ],
    });

    expect(result.href).toBe("/docs/skills#authoring-title");
    expect(result.title).toBe("Skill layout");
  });

  test("strips locale prefixes from search result hrefs", () => {
    const result = normalizeDocsSearchResult({
      url: "/zh-CN/docs/skills/",
      excerpt: "Run <mark>skills</mark>.",
      plain_excerpt: "Run skills.",
      meta: {
        title: "Skills",
      },
      sub_results: [
        {
          title: "Install skills",
          url: "/zh-CN/docs/skills/#install-skills",
          excerpt: "Install <mark>skills</mark>.",
          plain_excerpt: "Install skills.",
        },
      ],
    });

    expect(result.href).toBe("/docs/skills#install-skills");
  });

  test("wraps keyboard selection", () => {
    expect(
      nextDocsSearchIndex({
        currentIndex: -1,
        direction: "next",
        resultCount: 3,
      }),
    ).toBe(0);
    expect(
      nextDocsSearchIndex({
        currentIndex: 2,
        direction: "next",
        resultCount: 3,
      }),
    ).toBe(0);
    expect(
      nextDocsSearchIndex({
        currentIndex: 0,
        direction: "previous",
        resultCount: 3,
      }),
    ).toBe(2);
  });
});
