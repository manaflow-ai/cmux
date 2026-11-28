// Bundles a large first-party JSON import as `JSON.parse("…")` instead of esbuild's object
// literal. JavaScriptCore reads a JSON string with its JSON parser, several times faster than
// compiling the same data as script, so the page's first frame waits less for its data (the
// model catalog and the icon pack, cx-z9kz0). Only default imports exist for these files.
import { readFile } from "node:fs/promises";

const MIN_BYTES = 8 * 1024;

export const jsonParsePlugin = {
  name: "json-parse",
  setup(build) {
    build.onLoad({ filter: /\.json$/ }, async (args) => {
      if (args.path.includes("/node_modules/")) return undefined;
      const text = await readFile(args.path, "utf8");
      if (text.length < MIN_BYTES) return undefined;
      // Parse here first: a malformed file fails the build, not the page.
      const data = JSON.stringify(JSON.parse(text));
      return { contents: `export default JSON.parse(${JSON.stringify(data)});\n`, loader: "js" };
    });
  },
};
