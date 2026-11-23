// l10n-allow-file: benchmark output, not shipped UI.
// The chat pane's JavaScript startup, from page origin to first paint, with no host (restart-to-chat goal:
// the span `page.page_origin` to `agent_pane.painted`). Serves a built pane (the shipped one:
// `scripts/cmux-next/build-agent-pane-web.sh --out DIR`) the way the app does, with a stand-in
// `webkit.messageHandlers.agentSession` that answers `ready` and refuses the socket, and times in a fresh
// headless Chromium context per run:
//   fetched    pane.js responseEnd            (load)
//   firstPost  the page's first call to the host (its module graph evaluated and its first render ran)
//   rootDrawn  #root first has children       (first React commit)
//   fcp        first-contentful-paint
//   painted    the page's `pane.painted` call (what the app's `agent_pane.painted` is)
// plus bytes of the eager JS (pane.js and its modulepreload chunks). `--profile` adds one CPU-profiled
// run and lists the pane's source files by self time before first paint (needs the build's source maps:
// `--maps DIR`, a build of bundle.mjs with `--frame-sites`, see the README line printed on failure).
//
//   bun bench/pane-js-startup.mjs --dir /tmp/pane [--runs 9] [--throttle 4] [--profile --maps /tmp/panemaps]
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at < 0 ? fallback : (args[at + 1] ?? true);
};
const dir = path.resolve(String(opt("dir", "")));
if (!opt("dir") || !fs.existsSync(path.join(dir, "index.html"))) {
  console.error(
    "usage: bun bench/pane-js-startup.mjs --dir BUILT_PANE [--runs 9] [--throttle 1] [--profile --maps DIR]",
  );
  process.exit(2);
}
const runs = Number(opt("runs", 9));
const throttle = Number(opt("throttle", 1));
const profile = args.includes("--profile");
const maps = opt("maps", dir);

const index = fs.readFileSync(path.join(dir, "index.html"), "utf8");
const eager = ["pane.js", ...[...index.matchAll(/rel="modulepreload" href="([^"]+)"/g)].map((m) => m[1])];
const eagerSet = [...new Set(eager)];
const mime = { ".js": "text/javascript", ".css": "text/css", ".html": "text/html" };
const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(request) {
    const pathname = new URL(request.url).pathname;
    if (pathname === "/" || pathname === "/index.html")
      return new Response(index, { headers: { "Content-Type": "text/html" } });
    if (pathname === "/__snapshot/chat.js") {
      // `--copy`: the chat's drawn copy as the host serves it (chatSnapshot/shared.ts), a small one: what it
      // costs to draw is the sheets' load, not its markup. Without it, no copy is served.
      const copy = args.includes("--copy")
        ? JSON.stringify({
            v: 1,
            html: '<div class="acpmux-main"><div class="acpmux-scroll">restored chat</div></div>',
            width: 900,
            height: 700,
            root: {},
            body: {},
            sheets: [],
            styles: [],
            theme: "bench",
            savedAt: Date.now(),
          })
        : "null";
      return new Response(
        `self.__cmuxChatSnapshot=${copy};self.__cmuxChatSnapshotTheme="bench";self.dispatchEvent(new Event("cmux-restored-chat"));self.__cmuxChatSnapshotBoot?.();`,
        { headers: { "Content-Type": "text/javascript" } },
      );
    }
    const file = Bun.file(path.join(dir, pathname));
    if (!(await file.exists())) return new Response("not found", { status: 404 });
    return new Response(file, {
      headers: { "Content-Type": mime[path.extname(pathname)] ?? "application/octet-stream" },
    });
  },
});

const hostStub = () => {
  const t = (window.__bench = { posts: [], painted: 0, firstPost: 0, rootDrawn: 0 });
  const answer = (method) => {
    if (method === "ready" || method === "handshake")
      return { ok: true, value: { protocolVersion: 1, transport: "acpmux-bridge" } };
    if (method === "transport.open")
      return { ok: false, error: { code: "transport.connect_failed", origin: "native", message: "no host" } };
    return { ok: true, value: null };
  };
  window.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: async (request) => {
          const now = performance.now();
          t.firstPost ||= now;
          t.posts.push([request.method, Math.round(now)]);
          if (request.method === "pane.painted") t.painted ||= now;
          return answer(request.method);
        },
      },
    },
  };
  new MutationObserver((_, observer) => {
    const root = document.getElementById("root");
    if (root?.firstChild) {
      t.rootDrawn = performance.now();
      observer.disconnect();
    }
  }).observe(document, { childList: true, subtree: true });
};

const median = (values) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const browser = await chromium.launch({ headless: true, channel: "chrome" });
const url = `http://127.0.0.1:${server.port}/#${args.includes("--newtab") ? "newtab&new" : "session=bench"}`;

async function run(withProfile) {
  const context = await browser.newContext({ viewport: { width: 900, height: 700 } });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  if (throttle > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
  if (withProfile) {
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
    await cdp.send("Profiler.start");
  }
  await page.addInitScript(hostStub);
  await page.goto(url, { waitUntil: "commit" });
  await page.waitForFunction(() => window.__bench?.painted > 0 && window.__bench.rootDrawn > 0, null, {
    timeout: 30_000,
    polling: 25,
  });
  const got = await page.evaluate(() => {
    const paint = performance.getEntriesByName("first-contentful-paint")[0];
    const res = performance.getEntriesByType("resource");
    const pane = res.find((r) => r.name.endsWith("/pane.js"));
    const scripts = res.filter((r) => r.name.endsWith(".js"));
    return {
      fetched: pane?.responseEnd ?? 0,
      lastChunk: Math.max(...scripts.map((r) => r.responseEnd)),
      scriptsLoaded: scripts.length,
      firstPost: window.__bench.firstPost,
      rootDrawn: window.__bench.rootDrawn,
      fcp: paint?.startTime ?? 0,
      painted: window.__bench.painted,
      copyShown: window.__cmuxChatSnapshotShown?.at ?? 0,
    };
  });
  if (args.includes("--posts"))
    console.log("posts", JSON.stringify(await page.evaluate(() => window.__bench.posts.slice(0, 40))));
  let prof;
  if (withProfile) prof = (await cdp.send("Profiler.stop")).profile;
  await context.close();
  return { got, prof };
}

try {
  await run(false); // warm the browser process; not counted
  const rows = [];
  for (let i = 0; i < runs; i += 1) rows.push((await run(false)).got);
  const sizes = eagerSet.map((file) => [file, fs.statSync(path.join(dir, file)).size]);
  const total = sizes.reduce((sum, [, size]) => sum + size, 0);
  console.log(`pane ${dir}  runs ${runs}  cpu throttle ${throttle}x`);
  console.log(
    `eager js: ${eagerSet.length} files, ${(total / 1024).toFixed(0)} KiB (pane.js ${(sizes[0][1] / 1024).toFixed(0)} KiB)`,
  );
  for (const [file, size] of [...sizes].sort((a, b) => b[1] - a[1]).slice(0, 5))
    console.log(`  ${(size / 1024).toFixed(0).padStart(6)} KiB  ${file}`);
  for (const key of ["fetched", "lastChunk", "firstPost", "rootDrawn", "fcp", "copyShown", "painted"])
    console.log(
      `${key.padEnd(10)} median ${median(rows.map((r) => r[key]))
        .toFixed(0)
        .padStart(5)} ms   runs ${rows.map((r) => r[key].toFixed(0)).join(" ")}`,
    );
  if (profile) {
    const { prof } = await run(true);
    if (opt("profile-out")) fs.writeFileSync(String(opt("profile-out")), JSON.stringify(prof));
    await report(prof);
  }
} finally {
  await browser.close();
  server.stop(true);
}

/// Self time per source file from the CPU profile, through the build's source maps.
async function report(prof) {
  const { SourceMapConsumer } = await import("source-map-js");
  const consumers = new Map();
  const consumer = (file) => {
    if (!consumers.has(file)) {
      const mapFile = path.join(maps, `${file}.map`);
      consumers.set(
        file,
        fs.existsSync(mapFile) ? new SourceMapConsumer(JSON.parse(fs.readFileSync(mapFile, "utf8"))) : null,
      );
    }
    return consumers.get(file);
  };
  const nodes = new Map(prof.nodes.map((node) => [node.id, node]));
  const self = new Map();
  const dt = prof.timeDeltas;
  prof.samples.forEach((id, i) => {
    const node = nodes.get(id);
    const frame = node.callFrame;
    let label;
    const rel = frame.url.startsWith(`http://127.0.0.1:${server.port}/`)
      ? frame.url.slice(`http://127.0.0.1:${server.port}/`.length)
      : "";
    const map = rel ? consumer(rel) : null;
    if (map) {
      const at = map.originalPositionFor({ line: frame.lineNumber + 1, column: frame.columnNumber });
      label = at.source ? at.source.replace(/^.*?(node_modules\/|src\/)/, "$1") : `${rel} (unmapped)`;
    } else label = frame.url ? rel || frame.url : `(${frame.functionName || "native"})`;
    self.set(label, (self.get(label) ?? 0) + (dt[i] ?? 0) / 1000);
  });
  console.log("\ntop 10 source files by self time over the whole profiled load (ms, 100 us sampling):");
  for (const [label, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, Number(opt("top", 10))))
    console.log(`  ${ms.toFixed(1).padStart(7)}  ${label}`);
}
