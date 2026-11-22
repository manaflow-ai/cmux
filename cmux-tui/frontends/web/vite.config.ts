import { defineConfig } from "vite-plus";
import react from "@vitejs/plugin-react";
import { cmuxCheckConfig } from "../../../config/vite-plus/check";

export default defineConfig({
  // `vp check` reads `lint` and `fmt` from here; `vite build` ignores them.
  // This package was never linted before Vite+; its React refs/hooks warnings
  // are a backlog to fix, so they report without failing the check yet.
  ...cmuxCheckConfig({ allowWarnings: true }),
  plugins: [react()],
  test: {
    environment: "jsdom",
    setupFiles: "./test/setup.ts",
  },
});
