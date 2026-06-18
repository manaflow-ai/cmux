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
