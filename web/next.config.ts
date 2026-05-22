import "./app/env";
import path from "node:path";
import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";

if (
  process.env.VERCEL === "1" &&
  process.env.NEXT_ADAPTER_PATH &&
  process.env.VERCEL_PREVIEW_COMMENTS_ENABLED === "1"
) {
  // Vercel's Next adapter currently expects projectDir in modifyConfig,
  // but Next 16.2 only passes phase/nextVersion there.
  process.env.VERCEL_PREVIEW_COMMENTS_ENABLED = "0";
}

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");
const repoRoot = path.resolve(process.cwd(), "..");

const nextConfig: NextConfig = {
  outputFileTracingRoot: repoRoot,
  turbopack: {
    root: repoRoot,
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
