import "./app/env";
import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { poweredByHeader, securityHeaderRules } from "./security-headers";

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");
const webRoot = path.dirname(fileURLToPath(import.meta.url));

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

const nextConfig: NextConfig = {
  poweredByHeader,
  async redirects() {
    // Cover the HTML page plus its agent-readable .md/.txt variants, which were
    // live and advertised in llms.txt before the move.
    const exts = ["", ".md", ".txt"];
    return agentSlugMoves.flatMap(([from, to]) =>
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
  },
  async headers() {
    return securityHeaderRules;
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
