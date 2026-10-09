import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          REPO_BACKEND: "memory",
          JWT_SECRET: "test-jwt-secret-not-for-production",
          TEST_LOGIN_SECRET: "test-login-secret",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
