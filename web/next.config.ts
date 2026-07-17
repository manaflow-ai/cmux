import "./app/env";
import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { poweredByHeader, securityHeaderRules } from "./security-headers";

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");
const webRoot = path.dirname(fileURLToPath(import.meta.url));
const docsChannel = process.env.CMUX_DOCS_CHANNEL;
const isDocsZone = docsChannel === "release" || docsChannel === "nightly";
const releaseDocsOrigin =
  process.env.CMUX_RELEASE_DOCS_ORIGIN ?? "https://cmux-docs-release.vercel.app";
const nightlyDocsOrigin =
  process.env.CMUX_NIGHTLY_DOCS_ORIGIN ?? "https://cmux-docs-nightly.vercel.app";

// Agent landing pages moved under /agents/<agent>. Keep the old top-level
// slugs working with permanent redirects, for the bare English path and every
// locale-prefixed variant.
const localePrefix =
  ":locale(ja|zh-CN|zh-TW|ko|de|es|fr|it|da|pl|ru|bs|ar|no|pt-BR|th|tr|km|uk)";
const agentSlugMoves: [from: string, to: string][] = [
  ["/claude-code-terminal", "/agents/claude-code"],
  ["/codex-cli", "/agents/codex"],
  ["/opencode", "/agents/opencode"],
];
const baseNightlyMoves = ["", ".md", ".txt"].flatMap((ext) => [
  {
    source: `/docs/base${ext}`,
    destination: `/docs/nightly/base${ext}`,
    permanent: false,
  },
  {
    source: `/en/docs/base${ext}`,
    destination: `/docs/nightly/base${ext}`,
    permanent: false,
  },
]);

const nextConfig: NextConfig = {
  poweredByHeader,
  env: {
    CMUX_DOCS_CHANNEL: docsChannel ?? "",
  },
  assetPrefix: isDocsZone ? `/_docs-assets/${docsChannel}` : undefined,
  async rewrites() {
    if (isDocsZone) {
      return {
        beforeFiles: [
          {
            source: `/_docs-assets/${docsChannel}/_next/:path*`,
            destination: "/_next/:path*",
          },
        ],
      };
    }
    return {
      beforeFiles: [
        {
          source: "/_docs-assets/release/:path*",
          destination: `${releaseDocsOrigin}/:path*`,
        },
        {
          source: "/_docs-assets/nightly/:path*",
          destination: `${nightlyDocsOrigin}/:path*`,
        },
        {
          source: "/_docs-search/release/:path*",
          destination: `${releaseDocsOrigin}/pagefind/:path*`,
        },
        {
          source: "/_docs-search/nightly/:path*",
          destination: `${nightlyDocsOrigin}/pagefind/:path*`,
        },
        {
          source: "/docs/nightly",
          destination: `${nightlyDocsOrigin}/docs/getting-started`,
        },
        {
          source: "/docs/nightly/:path*",
          destination: `${nightlyDocsOrigin}/docs/:path*`,
        },
        {
          source: "/:locale/docs/nightly",
          destination: `${nightlyDocsOrigin}/:locale/docs/getting-started`,
        },
        {
          source: "/:locale/docs/nightly/:path*",
          destination: `${nightlyDocsOrigin}/:locale/docs/:path*`,
        },
        { source: "/docs", destination: `${releaseDocsOrigin}/docs` },
        {
          source: "/docs/:path*",
          destination: `${releaseDocsOrigin}/docs/:path*`,
        },
        {
          source: "/:locale/docs",
          destination: `${releaseDocsOrigin}/:locale/docs`,
        },
        {
          source: "/:locale/docs/:path*",
          destination: `${releaseDocsOrigin}/:locale/docs/:path*`,
        },
      ],
    };
  },
  async redirects() {
    // Cover the HTML page plus its agent-readable .md/.txt variants, which were
    // live and advertised in llms.txt before the move.
    const exts = ["", ".md", ".txt"];
    const agentRedirects = agentSlugMoves.flatMap(([from, to]) =>
      exts.flatMap((ext) => [
        // Bare English path (canonical, no locale prefix).
        { source: `${from}${ext}`, destination: `${to}${ext}`, permanent: true },
        // Explicit /en prefix (the agent-readable router accepts /en/... and
        // dotted variants bypass the locale middleware, so it must be covered).
        {
          source: `/en${from}${ext}`,
          destination: `${to}${ext}`,
          permanent: true,
        },
        // Every other locale prefix.
        {
          source: `/${localePrefix}${from}${ext}`,
          destination: `/:locale${to}${ext}`,
          permanent: true,
        },
      ]),
    );
    return [...(isDocsZone ? [] : baseNightlyMoves), ...agentRedirects];
  },
  async headers() {
    if (docsChannel !== "nightly") return securityHeaderRules;
    return securityHeaderRules.map((rule) => ({
      ...rule,
      headers: [
        ...rule.headers,
        { key: "X-Robots-Tag", value: "noindex, follow" },
      ],
    }));
  },
  turbopack: {
    root: webRoot,
  },
  images: {
    // AVIF first: for the detailed hero screenshot (crisp terminal text +
    // transparent rounded window corners) it rings far less than WebP at the
    // same size. Allow q100 so the hero can opt out of lossy degradation.
    formats: ["image/avif", "image/webp"],
    qualities: [75, 85],
    remotePatterns: [
      {
        protocol: "https",
        hostname: "github.com",
        pathname: "/*.png",
      },
    ],
  },
};

export default withNextIntl(nextConfig);
