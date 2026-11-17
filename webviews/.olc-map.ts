// Scratch (not committed): build the pane as chat-100k-flat does, with maps, and name profile frames.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { sourceMapper } from "./bench/sourceMapper";

const webviews = import.meta.dir;
const out = fs.mkdtempSync(path.join(os.tmpdir(), "olc-map-"));
const { build } = await import("vite");
await build({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out, emptyOutDir: true, sourcemap: true },
  logLevel: "error",
});
const assets = fs.readdirSync(path.join(out, "assets"));
console.log("ASSETS", assets.filter((name) => name.endsWith(".js")).join(" "));
const map = sourceMapper(out);
for (const spec of process.argv.slice(2)) {
  const [chunk, at] = spec.split("=");
  const [line, column] = at!.split(":").map(Number);
  const file = assets.find((name) => name.startsWith(`${chunk}-`) && name.endsWith(".js"));
  console.log("MAP", spec, file, map(file!, line!, column!));
}
