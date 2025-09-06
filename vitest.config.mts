import { defineConfig } from "vitest/config";

export default defineConfig({
  // Define a dedicated project for Convex function tests
  projects: [
    {
      test: {
        name: "convex",
        include: ["packages/convex/convex/**/*.test.ts"],
        environment: "edge-runtime",
        server: { deps: { inline: ["convex-test"] } },
      },
    },
  ],
});
