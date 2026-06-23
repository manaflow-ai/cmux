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
    return agentSlugMoves.flatMap(([from, to]) => [
      { source: from, destination: to, permanent: true },
      {
        source: `/${localePrefix}${from}`,
        destination: `/:locale${to}`,
        permanent: true,
      },
    ]);
  },
  async headers() {
    return securityHeaderRules;
  },
  turbopack: {
    root: webRoot,
  },
  images: {
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
