// FOCUS-RING: runs the focus-ring gate (focusRingGate.mjs) over stylesheets in place, for the app's
// bundle scripts that build CSS with esbuild or by joining sheets, which never read
// postcss.config.mjs. Every sheet the app ships goes through the gate, Vite-built or not.
//
//   bun scripts/postcss/gate-css.mjs <file.css>...
import { readFile, writeFile } from "node:fs/promises";
import postcss from "postcss";
import focusRingGate from "./focusRingGate.mjs";

const files = process.argv.slice(2);
if (!files.length) {
  console.error("usage: gate-css.mjs <file.css>...");
  process.exit(2);
}
const processor = postcss([focusRingGate()]);
for (const file of files) {
  const out = await processor.process(await readFile(file, "utf8"), { from: file, map: false });
  await writeFile(file, out.css);
}
