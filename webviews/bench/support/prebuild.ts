// l10n-allow-file: benchmark output, not shipped UI.
// One shared build of bench/web-ui-suite.ts (bench/support/sharedBuilds.ts), into OUT:
//   bun bench/support/prebuild.ts pane OUT
//   bun bench/support/prebuild.ts gallery OUT
//   bun bench/support/prebuild.ts page OUT PAGE_PATH [CONFIG]   (OUT is the pages directory; the page goes in a
//                                                                 directory of its own under it)
// Each builds what its bench builds by default, and marks the directory done last, so a build the suite killed at
// its bound is never taken.
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { buildBenchPage } from "./benchPage";
import { markSharedBuildDone, sharedPageKey } from "./sharedBuilds";

const webviews = path.resolve(import.meta.dir, "..", "..");
const [kind, outArg, pagePath, config = "vite.config.ts"] = process.argv.slice(2);
if (!outArg || !["pane", "gallery", "page"].includes(kind ?? "") || (kind === "page" && !pagePath)) {
  console.error("usage: prebuild.ts pane|gallery OUT | page OUT PAGE_PATH [CONFIG]");
  process.exit(2);
}
const out = path.resolve(outArg);
const started = performance.now();
const { build } = await import("vite");
let dir = out;
if (kind === "pane") {
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
  });
} else if (kind === "gallery") {
  // `gallery:build` (package.json), as bench/ui-stability.bench.ts runs it: the generated strings, then the gallery.
  const strings = Bun.spawnSync(["node", "scripts/pages/gen-strings.mjs"], {
    cwd: webviews,
    stdout: "ignore",
  });
  if (strings.exitCode !== 0) throw new Error(`gen-strings exited ${strings.exitCode}: ${strings.stderr.toString()}`);
  process.env.CMUX_GALLERY_OUT_DIR = out;
  await build({
    root: webviews,
    configFile: path.join(webviews, "vite.config.gallery.ts"),
    logLevel: "error",
  });
} else {
  dir = path.join(out, sharedPageKey(config, pagePath!));
  fs.mkdirSync(dir, { recursive: true });
  await buildBenchPage(pagePath!, { config }, dir);
}
markSharedBuildDone(dir);
console.log(
  `prebuild: ${kind}${pagePath ? ` ${pagePath}` : ""} built in ${((performance.now() - started) / 1000).toFixed(0)} s`,
);
