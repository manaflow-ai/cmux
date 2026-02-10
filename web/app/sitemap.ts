import type { MetadataRoute } from "next";

export default function sitemap(): MetadataRoute.Sitemap {
  const base = "https://cmux.dev";

  return [
    { url: base, lastModified: new Date(), changeFrequency: "weekly", priority: 1 },
    { url: `${base}/docs/getting-started`, lastModified: new Date(), changeFrequency: "monthly", priority: 0.9 },
    { url: `${base}/docs/concepts`, lastModified: new Date(), changeFrequency: "monthly", priority: 0.8 },
    { url: `${base}/docs/configuration`, lastModified: new Date(), changeFrequency: "monthly", priority: 0.8 },
    { url: `${base}/docs/keyboard-shortcuts`, lastModified: new Date(), changeFrequency: "monthly", priority: 0.7 },
    { url: `${base}/docs/api`, lastModified: new Date(), changeFrequency: "monthly", priority: 0.8 },
    { url: `${base}/docs/notifications`, lastModified: new Date(), changeFrequency: "monthly", priority: 0.8 },
    { url: `${base}/docs/changelog`, lastModified: new Date(), changeFrequency: "weekly", priority: 0.5 },
  ];
}
