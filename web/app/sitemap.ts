import type { MetadataRoute } from "next";
import { locales } from "../i18n/routing";

export default function sitemap(): MetadataRoute.Sitemap {
  const base = "https://cmux.com";

  const paths = [
    { path: "", lastModified: "2026-03-18", changeFrequency: "weekly" as const, priority: 1 },
    { path: "/blog", lastModified: "2026-03-18", changeFrequency: "weekly" as const, priority: 0.8 },
    { path: "/blog/show-hn-launch", lastModified: "2026-02-21", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/introducing-cmux", lastModified: "2026-02-12", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/zen-of-cmux", lastModified: "2026-02-27", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmd-shift-u", lastModified: "2026-03-04", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/getting-started", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.9 },
    { path: "/docs/concepts", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/configuration", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/keyboard-shortcuts", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/api", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/notifications", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/changelog", lastModified: "2026-03-18", changeFrequency: "weekly" as const, priority: 0.5 },
    { path: "/docs/browser-automation", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/community", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.5 },
    { path: "/wall-of-love", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.5 },
    { path: "/nightly", lastModified: "2026-03-18", changeFrequency: "weekly" as const, priority: 0.6 },
    { path: "/privacy-policy", lastModified: "2026-03-18", changeFrequency: "yearly" as const, priority: 0.3 },
    { path: "/terms-of-service", lastModified: "2026-03-18", changeFrequency: "yearly" as const, priority: 0.3 },
    { path: "/eula", lastModified: "2026-03-18", changeFrequency: "yearly" as const, priority: 0.3 },
  ];

  const entries: MetadataRoute.Sitemap = [];

  for (const { path, lastModified, changeFrequency, priority } of paths) {
    const alternates: Record<string, string> = {};
    for (const locale of locales) {
      alternates[locale] =
        locale === "en" ? `${base}${path}` : `${base}/${locale}${path}`;
    }
    alternates["x-default"] = `${base}${path}`;

    entries.push({
      url: `${base}${path}`,
      lastModified,
      changeFrequency,
      priority,
      alternates: { languages: alternates },
    });
  }

  return entries;
}
