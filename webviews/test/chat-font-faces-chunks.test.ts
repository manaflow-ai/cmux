// Choosing a bundled interface font loaded every bundled face: chatFonts/faces.ts imported all eight
// woff2 files, which the pane inlines as base64 (about 390 KB), to declare one. Each face is now an
// `import()` of its own. Bundled as the shipped pane bundles it (esbuild, code splitting, woff2 as
// data URLs), faces.ts's own chunk carries no face, and each face's chunk carries exactly one.
import { expect, test } from "bun:test";
import { build } from "esbuild";
import path from "node:path";

test("each bundled chat face is a chunk of its own, and faces.ts carries none", async () => {
  const entry = path.resolve(import.meta.dir, "../src/agent-session/acpmux/chatFonts/faces.ts");
  const result = await build({
    entryPoints: [entry],
    bundle: true,
    splitting: true,
    format: "esm",
    write: false,
    outdir: "/out",
    metafile: true,
    loader: { ".woff2": "dataurl" },
    logLevel: "silent",
  });
  const fonts = (inputs: Record<string, unknown>) => Object.keys(inputs).filter((input) => input.endsWith(".woff2"));
  const outputs = Object.values(result.metafile.outputs);
  const own = outputs.find((output) => output.entryPoint && path.resolve(output.entryPoint) === entry)!;
  expect(fonts(own.inputs)).toEqual([]);
  const faces = outputs.map((output) => fonts(output.inputs)).filter((list) => list.length > 0);
  expect(faces).toHaveLength(8);
  for (const list of faces) expect(list).toHaveLength(1);
});
