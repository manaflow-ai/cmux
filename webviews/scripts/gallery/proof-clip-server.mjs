// The gallery dev server proof-clip.mjs renders from, kept warm between clips: started once per checkout, it stays up
// until no page has asked it for anything for --idle minutes, so a second clip (after an edit, too: Vite reloads the
// changed module) costs seconds, not a build.
//
//   node scripts/gallery/proof-clip-server.mjs --root WEBVIEWS --state FILE [--idle 20]
//
// Compiled with Oxc's React Compiler (CMUX_REACT_COMPILER=oxc, reactCompiler.mjs): a cold stage in about 10 s
// where Babel's takes about 58 s (agent-pane.thinking-look, 1199 modules, fs-agent-lane-2, 2026-11-22). The
// compiler only adds memoization, so the pixels are the same. Writes {pid, port, url, compiler, root} to --state
// once it answers, and removes it on exit.
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({
  options: {
    root: { type: "string" },
    state: { type: "string" },
    idle: { type: "string", default: "20" },
    compiler: { type: "string", default: "oxc" },
  },
});
const root = path.resolve(args.root);
const idleMs = Number(args.idle) * 60_000;

const port = await new Promise((resolve, reject) => {
  const probe = net.createServer();
  probe.once("error", reject);
  probe.listen(0, "127.0.0.1", () => {
    const { port } = probe.address();
    probe.close(() => resolve(port));
  });
});
process.env.CMUX_GALLERY_DEV_PORT = String(port);
process.env.CMUX_REACT_COMPILER = args.compiler;
process.chdir(root);

let last = Date.now();
const { createServer } = await import(path.join(root, "node_modules/vite/dist/vite/node/index.js"));
const server = await createServer({
  configFile: path.join(root, "vite.config.gallery-dev.ts"),
  root,
  logLevel: "warn",
  // Its own dependency cache: checkouts sharing a linked node_modules would otherwise rewrite one node_modules/.vite.
  cacheDir: args.state.replace(/\.json$/, "-vite"),
  // A stale error overlay would be filmed as the component.
  server: {
    port,
    strictPort: true,
    hmr: { overlay: false },
    // A linked node_modules (proof-clip.mjs borrows one for a throwaway checkout) lives in another checkout.
    fs: { allow: [fs.realpathSync(path.join(root, "node_modules"))] },
  },
  plugins: [
    {
      name: "proof-clip-idle",
      configureServer(s) {
        s.middlewares.use((_req, _res, next) => {
          last = Date.now();
          next();
        });
      },
    },
  ],
});
await server.listen();

const url = `http://127.0.0.1:${port}/gallery`;
const state = { pid: process.pid, port, url, compiler: args.compiler, root, started: new Date().toISOString() };
fs.mkdirSync(path.dirname(args.state), { recursive: true });
fs.writeFileSync(args.state, `${JSON.stringify(state)}\n`);

let closing = false;
async function close() {
  if (closing) return;
  closing = true;
  try {
    // Only our own record: a newer server may have replaced it.
    if (JSON.parse(fs.readFileSync(args.state, "utf8")).pid === process.pid) fs.rmSync(args.state);
  } catch {}
  await server.close().catch(() => {});
  process.exit(0);
}
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, close);
setInterval(() => Date.now() - last > idleMs && close(), 15_000).unref();
