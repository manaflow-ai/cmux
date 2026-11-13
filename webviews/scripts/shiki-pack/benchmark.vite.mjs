// Measurement-only wrapper: production inputs, compiler, splitting and minification unchanged.
import config from "../../vite.config.ts";
import { shikiPackVite } from "./plugin.mjs";

export default {
  ...config,
  plugins: [...config.plugins, ...(process.env.CMUX_SHIKI_PACK === "1" ? [shikiPackVite()] : [])],
};
