// esbuild half of scripts/packed-shiki-data.mjs (CMUX-570, app size): the agent pane's and the
// pages' Shiki grammar and theme chunks (and Pierre's diff themes) store their JSON document
// raw-deflated and base64-encoded, and inflate it synchronously on import with the webviews app's
// runtime (src/shiki-packed/unpackJson.ts), so each chunk exports the same frozen object at the
// same moment. The webviews app (Vite) packs the same modules with the same function; only the
// bundler hook differs.
//
// The inflater (unpackJson and fflate) is imported only by the packed chunks, which load behind
// dynamic imports, so esbuild puts it in a chunk of its own that no page loads first
// (packed-shiki-data.test.ts builds a page and checks).
import { readFile } from "node:fs/promises";
import { PACKED_MODULE, packModule } from "../packed-shiki-data.mjs";

export const packedShikiPlugin = {
  name: "cmux-packed-shiki-data",
  setup(build) {
    build.onLoad({ filter: PACKED_MODULE }, async (args) => {
      const code = packModule(await readFile(args.path, "utf8"), args.path);
      return code == null ? undefined : { contents: code, loader: "js" };
    });
  },
};
