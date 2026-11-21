// Bundle the JSX interpreter and React as inert text, evaluated only inside the opaque artifact
// frame after Run. No CDN, module fetch, parent eval or bridge capability reaches that frame.
import { build } from "esbuild";
import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const id = "virtual:cmux-artifact-runtime";
const entry = fileURLToPath(new URL("../../src/agent-session/acpmux/conversation/artifactRuntime.ts", import.meta.url));
export async function artifactRuntimeCode({ metafile } = {}) {
  const result = await build({
    entryPoints: [entry],
    bundle: true,
    write: false,
    format: "iife",
    platform: "browser",
    minify: true,
    define: { "process.env.NODE_ENV": '"production"' },
    metafile: Boolean(metafile),
  });
  const code = result.outputFiles[0].text;
  if (metafile) {
    await writeFile(
      metafile,
      JSON.stringify({
        schema: 1,
        tool: "esbuild",
        kind: "embedded",
        embeddedBytes: Buffer.byteLength(code),
        inputs: result.metafile?.inputs ?? {},
        outputs: result.metafile?.outputs ?? {},
      }),
    );
  }
  return code;
}
export function artifactRuntimePlugin(options = {}) {
  return {
    name: "artifact-runtime",
    setup(builder) {
      builder.onResolve({ filter: /^virtual:cmux-artifact-runtime$/ }, () => ({ path: id, namespace: id }));
      builder.onLoad({ filter: /.*/, namespace: id }, async () => ({
        contents: `export default ${JSON.stringify(await artifactRuntimeCode(options))}`,
        loader: "js",
      }));
    },
  };
}
export function artifactRuntimeVite(options = {}) {
  return {
    name: "artifact-runtime",
    resolveId(source) {
      if (source === id) return `\0${id}`;
    },
    async load(source) {
      if (source === `\0${id}`) {
        this.addWatchFile(entry);
        return `export default ${JSON.stringify(await artifactRuntimeCode(options))}`;
      }
    },
  };
}
