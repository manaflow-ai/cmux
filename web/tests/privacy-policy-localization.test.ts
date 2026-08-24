import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

import middleware from "../proxy";
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

  test("contains no generated placeholder tokens", () => {
    for (const locale of locales) {
      expect(allStrings(privacyPolicyContent[locale]).join("\n")).not.toMatch(/CMUXOKEN\d+X/);
    }
  });

  test("uses Traditional Chinese rather than Simplified-only policy fragments", () => {
    const traditionalPolicy = allStrings(privacyPolicyContent["zh-TW"]).join("\n");
    for (const fragment of ["应用程序", "发送到我们的服务器", "诊断可靠性", "如果您通过", "我们会收集", "当您登录时", "电子邮件代码"]) {
      expect(traditionalPolicy).not.toContain(fragment);
    }
  });

  test("emits a current localized sitemap entry for every policy route", () => {
    const policyEntries = sitemap().filter((entry) =>
      entry.url.endsWith("/privacy-policy"),
    );
    expect(policyEntries).toHaveLength(locales.length);
    expect(policyEntries.every((entry) => entry.lastModified === "2026-07-10")).toBe(true);
  });

  test("serves every localized policy route without an English redirect", () => {
    for (const locale of locales) {
      const path = locale === "en" ? "/privacy-policy" : `/${locale}/privacy-policy`;
      const response = middleware(new NextRequest(`https://cmux.com${path}`));
      expect(response.status).toBe(200);
      expect(response.headers.get("location")).toBeNull();
    }
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
