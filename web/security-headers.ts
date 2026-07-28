export const poweredByHeader = false;

export const securityHeaders = [
  { key: "Content-Security-Policy", value: "base-uri 'self'; object-src 'none'; frame-ancestors 'none'" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()" },
];

export const publicMarketingCacheHeaders = [
  {
    key: "Cache-Control",
    value: "public, s-maxage=86400, stale-while-revalidate=604800",
  },
];

export const privateShareHeaders = [
  { key: "Referrer-Policy", value: "no-referrer" },
  { key: "X-Robots-Tag", value: "noindex, nofollow" },
  { key: "Cache-Control", value: "private, no-store" },
];

const localePrefix =
  ":locale(ja|zh-CN|zh-TW|ko|de|es|fr|it|da|pl|ru|bs|ar|no|pt-BR|th|tr|km|uk)";

const publicMarketingSources = [
  `/${localePrefix}/docs/:path*`,
  `/${localePrefix}/blog/:path*`,
  `/${localePrefix}/agents/:path*`,
  `/${localePrefix}/guides`,
  `/${localePrefix}/compare/:path*`,
  `/${localePrefix}/best-terminal-for-mac`,
  `/${localePrefix}/built-on-ghostty`,
  `/${localePrefix}/community`,
  `/${localePrefix}/nightly`,
  `/${localePrefix}/assets`,
  `/${localePrefix}/wall-of-love`,
];

const privateShareSources = [
  "/share/:code",
  "/en/share/:code",
  `/${localePrefix}/share/:code`,
];

export const securityHeaderRules = [
  {
    source: "/:path*",
    headers: securityHeaders,
  },
  ...publicMarketingSources.map((source) => ({
    source,
    headers: publicMarketingCacheHeaders,
  })),
  ...privateShareSources.map((source) => ({
    source,
    headers: privateShareHeaders,
  })),
];
