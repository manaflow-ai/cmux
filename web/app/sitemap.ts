import type { MetadataRoute } from "next";
import { locales } from "../i18n/routing";

export default function sitemap(): MetadataRoute.Sitemap {
  const base = "https://cmux.com";

  const paths = [
    { path: "", lastModified: new Date(), changeFrequency: "weekly" as const, priority: 1 },
    { path: "/blog", lastModified: new Date(), changeFrequency: "weekly" as const, priority: 0.8 },
    { path: "/blog/show-hn-launch", lastModified: "2026-02-21", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/introducing-cmux", lastModified: "2026-02-12", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/zen-of-cmux", lastModified: "2026-02-27", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmd-shift-u", lastModified: "2026-03-04", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/getting-started", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.9 },
    { path: "/docs/concepts", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/configuration", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/keyboard-shortcuts", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/api", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/notifications", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/changelog", lastModified: new Date(), changeFrequency: "weekly" as const, priority: 0.5 },
    { path: "/docs/browser-automation", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/community", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.5 },
    { path: "/wall-of-love", lastModified: new Date(), changeFrequency: "monthly" as const, priority: 0.5 },
    { path: "/nightly", lastModified: new Date(), changeFrequency: "weekly" as const, priority: 0.6 },
  ];

  const entries: MetadataRoute.Sitemap = [];

  for (const { path, lastModified, changeFrequency, priority } of paths) {
    const alternates: Record<string, string> = {};
    for (const locale of locales) {
      alternates[locale] =
        locale === "en" ? `${base}${path}` : `${base}/${locale}${path}`;
    }

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
