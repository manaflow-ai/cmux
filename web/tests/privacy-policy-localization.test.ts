import { describe, expect, test } from "bun:test";

import {
  privacyPolicyContent,
  type PrivacyPolicyContent,
} from "../app/[locale]/(legal)/privacy-policy/content";
import sitemap from "../app/sitemap";
import { locales } from "../i18n/routing";

const markdownLinkPattern = /\[[^\]]+]\((https?:\/\/[^)]+|mailto:[^)]+)\)/g;

describe("privacy policy localization", () => {
  test("provides complete content for every routed locale", () => {
    expect(Object.keys(privacyPolicyContent)).toEqual([...locales]);

    const englishShape = contentShape(privacyPolicyContent.en);
    for (const locale of locales) {
      const content = privacyPolicyContent[locale];
      expect(contentShape(content)).toEqual(englishShape);
      expect(allStrings(content).every((value) => value.trim().length > 0)).toBe(true);
      if (locale !== "en") expect(content.title).not.toBe(privacyPolicyContent.en.title);
    }
  });

  test("preserves legal and contact link targets in every translation", () => {
    const englishTargets = linkTargets(privacyPolicyContent.en);
    for (const locale of locales) {
      expect(linkTargets(privacyPolicyContent[locale])).toEqual(englishTargets);
    }
  });

  test("emits a current localized sitemap entry for every policy route", () => {
    const policyEntries = sitemap().filter((entry) =>
      entry.url.endsWith("/privacy-policy"),
    );
    expect(policyEntries).toHaveLength(locales.length);
    expect(policyEntries.every((entry) => entry.lastModified === "2026-07-10")).toBe(true);
  });
});

function allStrings(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(allStrings);
  if (value && typeof value === "object") {
    return Object.values(value).flatMap(allStrings);
  }
  return [];
}

function contentShape(content: PrivacyPolicyContent): unknown {
  const shape = (value: unknown): unknown => {
    if (typeof value === "string") return "string";
    if (Array.isArray(value)) return value.map(shape);
    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.entries(value).map(([key, nested]) => [key, shape(nested)]),
      );
    }
    return typeof value;
  };
  return shape(content);
}

function linkTargets(content: PrivacyPolicyContent): string[] {
  return allStrings(content)
    .flatMap((value) => [...value.matchAll(markdownLinkPattern)].map((match) => match[1]!))
    .sort();
}
