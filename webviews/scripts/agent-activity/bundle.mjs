import { build } from "esbuild";
import { writeFile } from "node:fs/promises";
import { sharedReactExternalPlugin } from "../shared-react-runtime.mjs";

const [entry, outfile, metafile] = process.argv.slice(2);
if (!entry || !outfile) throw new Error("usage: bundle.mjs ENTRY OUTFILE [METAFILE]");
const result = await build({
  entryPoints: [entry],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: true,
  legalComments: "none",
  outfile,
  metafile: Boolean(metafile),
  logLevel: "warning",
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [sharedReactExternalPlugin()],
});
if (metafile) {
  // esbuild's CLI-compatible JSON is useful to the attribution report and keeps Activity in the
  // same report family as Pages and AgentPane.
  await writeFile(metafile, JSON.stringify(result.metafile));
}
