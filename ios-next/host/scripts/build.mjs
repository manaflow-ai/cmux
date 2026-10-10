// Bundles src/cli.ts and src/tools/probe.ts into dist/ (native deps stay external).
import { build } from "esbuild";

const common = {
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  sourcemap: true,
  external: ["node-datachannel", "node-pty", "ws", "@agentclientprotocol/sdk", "bufferutil", "utf-8-validate"],
  banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" },
};
await build({ ...common, entryPoints: ["src/cli.ts"], outfile: "dist/cli.mjs" });
await build({ ...common, entryPoints: ["src/tools/probe.ts"], outfile: "dist/probe.mjs" });
console.log("built dist/cli.mjs dist/probe.mjs");
