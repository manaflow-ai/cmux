import { defineWranglerConfig } from "wrangler/experimental-config";

export default defineWranglerConfig({
  assetsDirectory: "../../apps/web/dist",
  types: { generate: false },
  dev: { port: 8787 },
});
