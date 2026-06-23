import "./app/env";
import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { poweredByHeader, securityHeaderRules } from "./security-headers";

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");
const webRoot = path.dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  poweredByHeader,
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
