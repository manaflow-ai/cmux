import { defineConfig } from "vite-plus";
import { cmuxCheckConfig } from "../../config/vite-plus/check";

export default defineConfig({
  ...cmuxCheckConfig({ fmtIgnorePatterns: ["conformance/memory-vectors.json.gz"] }),
  test: { testTimeout: 60_000 },
});
