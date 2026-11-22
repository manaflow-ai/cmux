// Raw fs.watch (FSEvents) latency vs Vite's watcher on macOS for one file save; run in webviews/.
import fs from "node:fs"; import path from "node:path";
import { createServer } from "vite";
const file = path.resolve("src/pages/settings/components/SettingsApp.tsx");
const orig = fs.readFileSync(file, "utf8");
const server = await createServer({ configFile: "vite.config.ts", server: { port: 4419, strictPort: true, ...(process.env.NOFSE ? { watch: { useFsEvents: false, usePolling: false } } : {}) }, logLevel: "silent" });
await server.listen();
let t0 = 0, raw = null, vite = null;
fs.watch(path.dirname(file), (ev, name) => { if (name === path.basename(file) && raw == null) raw = performance.now() - t0; });
server.watcher.on("change", (f) => { if (f === file && vite == null) vite = performance.now() - t0; });
const rows = []; const t1 = performance.now();
try {
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 300));
    raw = vite = null; t0 = performance.now();
    fs.writeFileSync(file, i % 2 ? orig : orig + "\n");
    await new Promise((r) => setTimeout(r, 400));
    rows.push([raw?.toFixed(0), vite?.toFixed(0)]);
  }
} finally { fs.writeFileSync(file, orig); }
console.log("raw fs.watch / vite watcher ms:", rows.map((r) => r.join("/")).join(" "));
console.log("watch options:", JSON.stringify(server.config.server.watch));
await server.close(); process.exit(0);
