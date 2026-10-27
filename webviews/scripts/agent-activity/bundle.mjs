// Bundles the Agent Activity screen (src/agent-activity/main.tsx) for
// scripts/cmux-next/build-agent-activity-web.sh: <outdir>/app.js and <outdir>/app.css, the same
// esbuild options as before, with React imported from the one shared file every web tree uses
// (scripts/shared/shared-react.mjs, cmux-page://cmux.shared/). Prints that file's URL, which the
// page preloads.
//
//   bun scripts/agent-activity/bundle.mjs <outdir>
import { build } from "esbuild";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildSharedReact, sharedReactEsbuildPlugin } from "../shared/shared-react.mjs";

const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const [outdir] = process.argv.slice(2);
if (!outdir) {
  console.error("usage: bundle.mjs <outdir>");
  process.exit(2);
}
const { url } = await buildSharedReact();
await build({
  absWorkingDir: webviewsRoot,
  entryPoints: ["src/agent-activity/main.tsx"],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: true,
  outfile: path.join(path.resolve(outdir), "app.js"),
  logLevel: "warning",
  plugins: [sharedReactEsbuildPlugin(url)],
});
process.stdout.write(`${url}\n`);
