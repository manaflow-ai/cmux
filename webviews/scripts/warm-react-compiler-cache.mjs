// Fills CMUX_VITE_TRANSFORM_CACHE (reactCompiler.mjs) with the React Compiler's output for the agent
// pane's module graph, once, before scripts/ci/run-webviews-tests.sh starts its pools. The browser
// files start together, each with a Vite of its own, and all of them missed the cache while the first
// one compiled App.tsx (33 s alone, and more beside the others). Run from webviews/:
//   CMUX_VITE_TRANSFORM_CACHE=DIR bun scripts/warm-react-compiler-cache.mjs [ENTRY...]
// ENTRY defaults to the pane's dev entry and the gallery's pane mount. A module it cannot transform is
// skipped: a test file that needs it reports the error itself.
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";

if (!process.env.CMUX_VITE_TRANSFORM_CACHE) {
  console.error("warm-react-compiler-cache: CMUX_VITE_TRANSFORM_CACHE is not set");
  process.exit(2);
}
const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const entries = process.argv.slice(2);
if (entries.length === 0) entries.push("src/agent-session/acpmux/dev.tsx", "src/agent-session/acpmux/mount.tsx");
const started = performance.now();
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { middlewareMode: true, hmr: false, ws: false, preTransformRequests: false },
  optimizeDeps: { noDiscovery: true, include: [] },
  logLevel: "error",
});
const seen = new Set();
let failed = 0;
// First-party source only: dependencies and virtual modules never reach the React Compiler pass.
const firstParty = (file) =>
  file.startsWith(webviews + path.sep) &&
  !file.includes(`${path.sep}node_modules${path.sep}`) &&
  /\.[cm]?[jt]sx?$/.test(file);
const walk = async (file) => {
  if (seen.has(file) || !firstParty(file)) return;
  seen.add(file);
  const url = `/@fs${file}`;
  try {
    await server.transformRequest(url);
  } catch {
    failed += 1;
    return;
  }
  const module = await server.moduleGraph.getModuleByUrl(url);
  const next = [...(module?.importedModules ?? [])].map((imported) => imported.file).filter(Boolean);
  await Promise.all(next.map(walk));
};
try {
  await Promise.all(entries.map((entry) => walk(path.resolve(webviews, entry))));
} finally {
  await server.close();
}
console.log(
  `warm-react-compiler-cache: ${seen.size} modules (${failed} skipped) in ${Math.round((performance.now() - started) / 1000)} s`,
);
