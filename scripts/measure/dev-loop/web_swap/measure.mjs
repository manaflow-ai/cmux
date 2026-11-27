// The web_swap loop of goal dev-loop-ceiling: N saves of the agent pane's ComposerFoot.tsx through the dev
// server a person runs (`cmux live start --worktree` -> web-overlay.sh server --local -> `vp dev` on
// webviews/vite.config.ts, /agent-pane/), each split into stages, and each stage's floor measured on its own.
//   node measure.mjs OUT_JSON N --engine chromium|webkit [--host BIN]
// Like webviews/scripts/hot-reload-proof.mjs, whose setup this follows: the edits go to a copy of the
// checkout's sources in a temporary directory, and Vite runs in this process (createServer on the same
// config, with CMUX_VITE_TRANSFORM_CACHE as web-overlay.sh sets it) so its watcher, transform and HMR socket
// can be timed. The page: Playwright Chromium (Linux) or a WKWebView host (macOS, host.swift: fleet Macs
// take no Playwright). Every time is epoch milliseconds on this machine's clock.
import path from "node:path";
import os from "node:os";
import fs from "node:fs/promises";
import { watch as fsWatch } from "node:fs";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../../..");
const ownWebviews = path.join(root, "webviews");
const requireWebviews = createRequire(path.join(ownWebviews, "package.json"));
const { createServer } = await import(pathToFileURL(requireWebviews.resolve("vite")).href);

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const positional = args.filter((arg, i) => !arg.startsWith("--") && !args[i - 1]?.startsWith("--"));
const outJson = path.resolve(positional[0] ?? "web_swap.json");
const N = Number(positional[1] ?? 5);
const engine = flag("--engine") ?? (process.platform === "darwin" ? "webkit" : "chromium");
const hostBin = flag("--host");
const WARMUP = 2;
const SOURCES = ["webviews", "config", "schemas", "web/data", "Resources/markdown-viewer"];
const PANE = "src/agent-session/acpmux";
const FILE = `${PANE}/ComposerFoot.tsx`;
const CSS_FILE = `${PANE}/bottomStack.css`;
const now = () => performance.timeOrigin + performance.now();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const median = (xs) => {
  const s = xs.filter((x) => typeof x === "number").sort((a, b) => a - b);
  return s.length ? (s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2) : null;
};
const r1 = (x) => (typeof x === "number" ? Math.round(x * 10) / 10 : x);

const report = {
  schema: "dev-loop-ceiling/loop/v1",
  loop: "web_swap",
  commit: null,
  host: os.hostname(),
  measured_at: new Date().toISOString(),
  target: "",
  error: null,
  rounds: [],
  floors_ms: { fs_event: [], hmr_send: [], transform: [], apply: [], paint: [] },
  graph: {
    fs_event: [],
    hmr_send: ["fs_event"],
    transform: ["fs_event"],
    apply: ["hmr_send", "transform"],
    paint: ["apply"],
  },
  notes: [],
};
const notes = report.notes;

const scratch = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "dev-loop-web-swap-")));
const webviews = path.join(scratch, "webviews");
let server;
let browser;
let hostProcess;
const cleanup = async () => {
  try {
    await browser?.close();
  } catch {}
  if (hostProcess && hostProcess.exitCode === null) hostProcess.kill("SIGTERM");
  try {
    await server?.close();
  } catch {}
  await fs.rm(scratch, { recursive: true, force: true });
};
for (const [signal, code] of [
  ["SIGINT", 130],
  ["SIGTERM", 143],
])
  process.on(signal, () => cleanup().finally(() => process.exit(code)));

// Messages from the page, by event, each resolving the oldest waiter (or queued until one comes).
const inbox = new Map();
const deliver = (event, data) => {
  const box = inbox.get(event) ?? { queue: [], waiters: [] };
  inbox.set(event, box);
  const waiter = box.waiters.shift();
  if (waiter) waiter(data);
  else box.queue.push(data);
};
const receive = (event, timeoutMs = 20_000) =>
  new Promise((resolve, reject) => {
    const box = inbox.get(event) ?? { queue: [], waiters: [] };
    inbox.set(event, box);
    if (box.queue.length) return resolve(box.queue.shift());
    const timer = setTimeout(() => {
      box.waiters.splice(box.waiters.indexOf(done), 1);
      reject(new Error(`no ${event} from the page in ${timeoutMs} ms`));
    }, timeoutMs);
    const done = (data) => {
      clearTimeout(timer);
      resolve(data);
    };
    box.waiters.push(done);
  });

// Server-side boundaries, by file: watcher change events, HMR update sends, module transforms.
const marks = { change: [], send: [], transform: [], hooks: [], all: [], arrive: [], phase: [], stall: [] };
// Event-loop stalls: a 1 ms timer whose late firings (over 4 ms) are recorded, so a wait inside a stage can be
// told apart from work on this thread that the stage queued behind.
{
  let last = now();
  setInterval(() => {
    const at = now();
    if (at - last > 4) marks.stall.push({ start: last, end: at });
    last = at;
  }, 1).unref();
}
const timing = {
  name: "dev-loop-timing",
  configureServer(viteServer) {
    // Each plugin's own time in the update hooks (watch to HMR send) and in the transform of the edited
    // module, so the stages' insides have names. Rolldown's native plugins have no JS hook to wrap.
    for (const plugin of viteServer.config.plugins) {
      for (const hook of ["hotUpdate", "handleHotUpdate", "transform", "load"]) {
        const value = plugin[hook];
        const fn = typeof value === "function" ? value : value?.handler;
        if (typeof fn !== "function") continue;
        // Only the edited module's calls are timed; every other call goes straight through, sync stays sync.
        const wrapped = function (...hookArgs) {
          const first = hookArgs[0];
          const subject = hook === "transform" ? hookArgs[1] : hook === "load" ? first : first?.file;
          if (typeof subject !== "string" || !subject.includes("ComposerFoot")) return fn.apply(this, hookArgs);
          const start = now();
          const record = () => marks.hooks.push({ plugin: plugin.name, hook, start, end: now() });
          const result = fn.apply(this, hookArgs);
          if (result && typeof result.then === "function") return result.finally(record);
          record();
          return result;
        };
        if (typeof value === "function") plugin[hook] = wrapped;
        else value.handler = wrapped;
      }
    }
    viteServer.watcher.on("change", (file) => marks.change.push({ file, at: now() }));
    const client = viteServer.environments?.client;
    const hot = client?.hot ?? viteServer.hot ?? viteServer.ws;
    const send = hot.send.bind(hot);
    hot.send = (payload, ...rest) => {
      const at = now();
      if (payload && typeof payload === "object" && payload.type === "update")
        marks.send.push({ at, paths: payload.updates.map((update) => update.path) });
      if (payload && typeof payload === "object" && payload.type === "full-reload") marks.send.push({ at, reload: true });
      return send(payload, ...rest);
    };
    hot.on("dev-loop:debug", (data) => process.env.DEV_LOOP_DEBUG && console.error(`page debug: ${JSON.stringify(data).slice(0, 400)}`));
    for (const event of ["ready", "round", "pong", "frames", "apply", "css"])
      hot.on(`dev-loop:${event}`, (data) => deliver(event, data));
    const transformRequest = client.transformRequest.bind(client);
    client.transformRequest = async (url, options) => {
      const start = now();
      const result = await transformRequest(url, options);
      const mark = { url, start, end: now() };
      marks.all.push(mark);
      if (url.includes("ComposerFoot")) marks.transform.push(mark);
      return result;
    };
    // The edited module's phases inside transformRequest (resolve, load, the plugin transform), each [start, end].
    const container = client.pluginContainer;
    for (const method of ["resolveId", "load", "transform"]) {
      const original = container[method].bind(container);
      container[method] = async (...callArgs) => {
        const subject = method === "transform" ? callArgs[1] : callArgs[0];
        if (typeof subject !== "string" || !subject.includes("ComposerFoot")) return original(...callArgs);
        const start = now();
        try {
          return await original(...callArgs);
        } finally {
          marks.phase.push({ method, start, end: now() });
        }
      };
    }
    // When the page's request for the module reaches the server (before Vite's own middlewares).
    viteServer.middlewares.use((request, _response, next) => {
      if (request.url?.includes("ComposerFoot")) marks.arrive.push({ url: request.url, at: now() });
      next();
    });
    // The apply floor's pre-transformed copies of the component, under /__dev_loop_variant/N.js.
    viteServer.middlewares.use((request, response, next) => {
      const match = request.url?.match(/^\/__dev_loop_variant\/(\d+)\.js/);
      if (!match || !variants.has(match[1])) return next();
      response.setHeader("Content-Type", "text/javascript");
      response.setHeader("Cache-Control", "no-store");
      response.end(variants.get(match[1]));
    });
  },
  transformIndexHtml: {
    order: "post",
    handler: (html, context) =>
      context.path?.includes("acpmux")
        ? html.replace("</head>", `<script type="module" src="/__dev_loop_page.ts"></script></head>`)
        : html,
  },
};
const variants = new Map();

const startProfile = async () => {
  const inspector = await import("node:inspector/promises");
  const session = new inspector.Session();
  session.connect();
  await session.post("Profiler.enable");
  await session.post("Profiler.setSamplingInterval", { interval: 100 });
  await session.post("Profiler.start");
  return session;
};
const stopProfile = async (session, value) => {
  const { profile } = await session.post("Profiler.stop");
  session.disconnect();
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const self = new Map();
  const deltas = profile.timeDeltas;
  profile.samples.forEach((id, i) => {
    const frame = byId.get(id).callFrame;
    const key = `${frame.functionName || "(anon)"} ${frame.url.replace(/^.*node_modules\//, "").replace(/^file:\/\/.*\/webviews\//, "")}:${frame.lineNumber}`;
    self.set(key, (self.get(key) ?? 0) + (deltas[i + 1] ?? 0) / 1000);
  });
  const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 30);
  console.error(`profile ${value}: ${r1((profile.endTime - profile.startTime) / 1000)} ms\n${top.map(([k, ms]) => `  ${r1(ms)} ms ${k}`).join("\n")}`);
};

const status = { measured: false };
try {
  const { execFileSync } = await import("node:child_process");
  report.commit = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  const skip = new Set([path.join(ownWebviews, "node_modules"), path.join(ownWebviews, "dist")]);
  for (const source of SOURCES)
    await fs.cp(path.join(root, source), path.join(scratch, source), {
      recursive: true,
      filter: (from) => !skip.has(from),
    });
  await fs.symlink(path.join(ownWebviews, "node_modules"), path.join(webviews, "node_modules"), "dir");
  await fs.copyFile(path.join(here, "page.ts"), path.join(webviews, "__dev_loop_page.ts"));
  // The same React Compiler output cache web-overlay.sh gives `vp dev` (keyed by the module's text: every
  // probe edit below is new text, so a miss, as a person's save is).
  process.env.CMUX_VITE_TRANSFORM_CACHE ??= path.join(scratch, "transforms");

  server = await createServer({
    configFile: path.join(webviews, "vite.config.ts"),
    root: webviews,
    cacheDir: path.join(scratch, "vite-cache"),
    server: {
      port: 0,
      strictPort: false,
      host: "127.0.0.1",
      fs: { allow: [scratch, path.join(ownWebviews, "node_modules")] },
    },
    plugins: [timing],
    logLevel: "warn",
  });
  await server.listen();
  const { port } = server.httpServer.address();
  const url = `http://127.0.0.1:${port}/agent-pane/?mock`;

  if (engine === "webkit") {
    if (!hostBin) throw new Error("--engine webkit needs --host (host.swift built)");
    hostProcess = spawn(hostBin, [url], { stdio: ["ignore", "inherit", "inherit"] });
  } else {
    const { chromium } = requireWebviews("playwright");
    browser = await chromium.launch({
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
      args: ["--no-sandbox"],
      handleSIGINT: false,
      handleSIGTERM: false,
    });
    const page = await browser.newPage({ viewport: { width: 980, height: 820 } });
    page.on("pageerror", (error) => console.error(`page error: ${error.message}`));
    page.on("response", (response) => process.env.DEV_LOOP_DEBUG && response.status() >= 400 && console.error(`page: ${response.status()} ${response.url()}`));
    page.on("console", (message) => process.env.DEV_LOOP_DEBUG && console.error(`page: ${message.text().slice(0, 300)}`));
    await page.goto(url);
  }
  const ready = await receive("ready", 180_000);
  if (process.env.DEV_LOOP_DEBUG) {
    const mod = await server.environments.client.transformRequest("/src/agent-session/acpmux/ComposerFoot.tsx");
    console.error(`debug module head: ${mod.code.slice(0, 1200)}\n...\ndebug module tail: ${mod.code.slice(-1500)}`);
  }
  console.error(`web_swap: pane ready (${ready.href}, ${JSON.stringify(ready.modules)})`);

  // Clock: page offset from round trips over the HMR socket; the minimum round trip's sample is the truest.
  // A ping can land while the page reloads (a cold dep optimizer full-reloads it once it finds a
  // late dependency), so a lost one is sent again; a late pong of an earlier id is dropped.
  const pings = [];
  for (let id = 0, lost = 0; id < Math.max(20, 4 * N); id += 1) {
    const hot = server.environments.client.hot;
    hot.send("dev-loop:ping", { id, sent: now() });
    let pong = null;
    while (!pong) {
      const got = await receive("pong", 2_000).catch(() => null);
      if (got && got.id !== id) continue;
      if (got) pong = got;
      else if (++lost > 15) throw new Error(`no pong from the page in ${lost} tries of 2000 ms`);
      else hot.send("dev-loop:ping", { id, sent: now() });
    }
    const back = now();
    pings.push({ rtt: back - pong.sent, offset: pong.received - (pong.sent + back) / 2 });
    await sleep(20);
  }
  pings.sort((a, b) => a.rtt - b.rtt);
  const offset = pings[0].offset; // page clock minus server clock
  const pageTime = (t) => (typeof t === "number" ? t - offset : null);
  notes.push(
    `Page clock offset ${r1(offset)} ms (from the min-RTT ping of ${pings.length}, rtt ${r1(pings[0].rtt)} ms); page times are corrected by it.`,
  );

  const original = await fs.readFile(path.join(webviews, FILE), "utf8");
  const anchor = 'className="acpmux-composer-bar acpmux-composer-foot"';
  if (!original.includes(anchor)) throw new Error(`the probe edit no longer applies to ${FILE}`);
  const edited = (value) => original.replace(anchor, `data-hot-reload-probe="${value}" $&`);
  const absolute = path.join(webviews, FILE);

  // One save: write the edited text, wait for the page's commit and paint, split it at each boundary.
  const round = async (value) => {
    const fromChange = marks.change.length;
    const fromSend = marks.send.length;
    const fromTransform = marks.transform.length;
    const fromHooks = marks.hooks.length;
    const fromAll = marks.all.length;
    const fromArrive = marks.arrive.length;
    const fromPhase = marks.phase.length;
    const fromStall = marks.stall.length;
    server.environments.client.hot.send("dev-loop:expect", { value, since: now() + offset - 5 });
    await sleep(30);
    // DEV_LOOP_PROFILE=1: a CPU profile of this process from the write to the page's commit, top self time printed.
    const profiler = process.env.DEV_LOOP_PROFILE ? await startProfile() : null;
    const write = now();
    await fs.writeFile(absolute, edited(value));
    const seen = await receive("round", 20_000);
    if (profiler) await stopProfile(profiler, value);
    if (seen.error)
      throw new Error(
        `round ${value}: ${seen.error} (changes ${JSON.stringify(marks.change.slice(fromChange))}, sends ${JSON.stringify(marks.send.slice(fromSend))}, transforms ${JSON.stringify(marks.transform.slice(fromTransform).map((mark) => mark.url))})`,
      );
    await sleep(300);
    const change = marks.change.slice(fromChange).find((mark) => mark.file === absolute)?.at;
    const send = marks.send.slice(fromSend).find((mark) => mark.reload || mark.paths?.some((p) => p.endsWith("ComposerFoot.tsx")));
    if (send?.reload) throw new Error(`round ${value}: Vite reloaded the page instead of a hot update`);
    const transforms = marks.transform.slice(fromTransform).filter((mark) => mark.url.includes("ComposerFoot.tsx"));
    // The transform that answered the page's own request for this update (its ?t= URL), else the first.
    const fetched = seen.fetch?.url ? new URL(seen.fetch.url) : null;
    const arrive = marks.arrive.slice(fromArrive).find((mark) => fetched && mark.url === `${fetched.pathname}${fetched.search}`)?.at;
    const transform =
      transforms.find((mark) => fetched && mark.url === `${fetched.pathname}${fetched.search}`) ?? transforms[0];
    const before = pageTime(seen.beforeUpdate);
    const after = pageTime(seen.afterUpdate);
    const commit = pageTime(seen.commit);
    const paint = pageTime(seen.paint);
    const fetchStart = pageTime(seen.fetch?.fetchStart);
    const responseEnd = pageTime(seen.fetch?.responseEnd);
    if ([change, send?.at, transform?.start, before, commit, paint].some((t) => typeof t !== "number"))
      throw new Error(
        `round ${value}: a boundary is missing ${JSON.stringify({ change, send: send?.at, transform, before, commit, paint })}`,
      );
    const e2e = paint - write;
    const stages = {
      fs_event: change - write,
      hmr_send: before - change,
      transform: transform.end - transform.start,
      // The client's fetch of the module outside the server's transform, its evaluation, the refresh
      // runtime's batch and React's commit.
      apply:
        (fetchStart !== null ? transform.start - fetchStart : 0) +
        (responseEnd !== null ? commit - responseEnd : commit - transform.end),
      paint: paint - commit,
    };
    const named = Object.values(stages).reduce((a, b) => a + b, 0);
    stages.unattributed = e2e - named;
    return {
      end_to_end_ms: r1(e2e),
      stages_ms: Object.fromEntries(Object.entries(stages).map(([k, v]) => [k, r1(v)])),
      detail_ms: {
        watch_to_hmr_sent: r1(send.at - change),
        hmr_sent_to_page: r1(before - send.at),
        before_update_to_fetch: fetchStart !== null ? r1(fetchStart - before) : null,
        fetch_to_transform_start: fetchStart !== null ? r1(transform.start - fetchStart) : null,
        transform_end_to_response_end: responseEnd !== null ? r1(responseEnd - transform.end) : null,
        response_end_to_after_update: responseEnd !== null && after !== null ? r1(after - responseEnd) : null,
        after_update_to_commit: after !== null ? r1(commit - after) : null,
        commit_to_raf: r1(pageTime(seen.raf) - commit),
        transforms_of_module: transforms.length,
        // Request arrival at the server, after the page's fetchStart and before transform start.
        fetch_to_arrive: fetchStart !== null && arrive !== undefined ? r1(arrive - fetchStart) : null,
        arrive_to_transform_start: arrive !== undefined ? r1(transform.start - arrive) : null,
        // The page's transform split: [phase, start, end] after its transformRequest start.
        transform_phases: marks.phase
          .slice(fromPhase)
          .filter((mark) => mark.start >= transform.start && mark.end <= transform.end + 0.5)
          .map((mark) => [mark.method, r1(mark.start - transform.start), r1(mark.end - transform.start)]),
        // Other modules transformed while the edited one was asked for (fetch start to transform end).
        concurrent_transforms: marks.all
          .slice(fromAll)
          .filter((mark) => !mark.url.includes("ComposerFoot") && mark.end > (fetchStart ?? transform.start) && mark.start < transform.end)
          .map((mark) => [mark.url.slice(0, 80), r1(mark.start - change), r1(mark.end - change)]),
        // Event-loop stalls over 4 ms from the file event to the commit, [start, end] after the file event.
        stalls: marks.stall
          .slice(fromStall)
          .filter((mark) => mark.end > change && mark.start < commit)
          .map((mark) => [r1(mark.start - change), r1(mark.end - change)]),
        // Each transformRequest of the module this round, [start, end] after the file event (the page's has `?t=`).
        transform_calls: transforms.map((mark) => ({ url: mark.url.replace(/^.*ComposerFoot/, "ComposerFoot"), start: r1(mark.start - change), end: r1(mark.end - change) })),
        // Each plugin's own hook time on the edited module this round: update hooks (inside watch to HMR
        // send) and transform/load (inside transform), summed per plugin and hook.
        plugin_hooks: Object.fromEntries(
          Object.entries(
            marks.hooks.slice(fromHooks).reduce((sum, mark) => {
              const key = `${mark.plugin}:${mark.hook}`;
              sum[key] = (sum[key] ?? 0) + (mark.end - mark.start);
              return sum;
            }, {}),
          )
            .filter(([, ms]) => ms >= 0.5)
            .sort((a, b) => b[1] - a[1])
            .map(([key, ms]) => [key, r1(ms)]),
        ),
      },
    };
  };

  let value = 0;
  for (let i = 0; i < WARMUP; i += 1) await round(`warm-${++value}`);
  for (let i = 0; i < N; i += 1) {
    report.rounds.push(await round(`r${++value}`));
    console.error(`web_swap: round ${i + 1}: ${JSON.stringify(report.rounds.at(-1))}`);
  }

  // Floors, N samples each (more where cheap), after the rounds, on the same server and page.
  // fs_event: a raw fs.watch on a fresh directory beside the edited file, write to callback.
  const probeDir = await fs.mkdtemp(path.join(webviews, PANE, ".dev-loop-fs-"));
  for (let i = 0; i < Math.max(N, 10); i += 1) {
    // A fresh name per round, and no callback counts before the write starts: FSEvents can deliver the
    // previous round's write late, which with start still 0 read as an epoch (1.8e12 ms) floor.
    const name = `probe-${i}.txt`;
    const file = path.join(probeDir, name);
    const sample = await new Promise((resolve, reject) => {
      let start = 0;
      const watcher = fsWatch(probeDir, (_event, changed) => {
        if (start === 0 || (changed && path.basename(String(changed)) !== name)) return;
        watcher.close();
        clearTimeout(timer);
        resolve(now() - start);
      });
      const timer = setTimeout(() => {
        watcher.close();
        reject(new Error("fs.watch never fired"));
      }, 5_000);
      setTimeout(() => {
        start = now();
        fs.writeFile(file, `${i}`).catch(reject);
      }, 50);
    });
    report.floors_ms.fs_event.push(r1(sample));
    await sleep(50);
  }
  await fs.rm(probeDir, { recursive: true, force: true });

  // hmr_send: one message over Vite's HMR socket to the page, half the round trip (and the one-way time
  // on the offset-corrected clock, which should agree).
  for (const ping of pings.slice(0, Math.max(N, 10))) report.floors_ms.hmr_send.push(r1(ping.rtt / 2));

  // transform: the edited module alone through the dev server's plugin pipeline (React Compiler, import
  // analysis, React Refresh), new text each time so the transform cache misses as a save does. Each result
  // is served as /__dev_loop_variant/K.js for the apply floor.
  const client = server.environments.client;
  for (let i = 0; i < Math.max(N, 5); i += 1) {
    const variant = `f${++value}`;
    const start = now();
    const result = await client.pluginContainer.transform(edited(variant), absolute);
    report.floors_ms.transform.push(r1(now() - start));
    variants.set(String(i), { variant, code: result.code });
  }
  // apply: the page imports a pre-transformed variant (fetch + evaluate) and runs React Refresh at once:
  // import to the commit that shows its probe value.
  for (const [key, { variant, code }] of [...variants]) {
    variants.set(key, code);
    client.hot.send("dev-loop:apply", { url: `/__dev_loop_variant/${key}.js`, value: variant, id: absolute });
    const applied = await receive("apply", 15_000);
    if (applied.error) throw new Error(`apply floor ${variant}: ${applied.error}`);
    report.floors_ms.apply.push(r1(applied.commit - applied.start));
    await sleep(200);
  }
  // paint: one frame interval, consecutive animation frame deltas.
  client.hot.send("dev-loop:frames", { count: Math.max(N, 30) });
  report.floors_ms.paint = (await receive("frames", 15_000)).deltas.map(r1);

  // Extra: the stylesheet edit (bottomStack.css), end to end only, as hot-reload-proof.mjs times it.
  const cssAbsolute = path.join(webviews, CSS_FILE);
  const cssOriginal = await fs.readFile(cssAbsolute, "utf8");
  report.stylesheet_rounds_ms = [];
  // The page waits for a custom property instead of an attribute: reuse the round message with a CSS probe.
  for (let i = 0; i < N; i += 1) {
    const css = `css${++value}`;
    client.hot.send("dev-loop:expect-css", { value: css });
    await sleep(30);
    const write = now();
    await fs.writeFile(cssAbsolute, `${cssOriginal}\n:root { --hot-reload-probe: ${css}; }\n`);
    const seen = await receive("css", 15_000).catch(() => null);
    if (!seen || seen.error) {
      notes.push(`stylesheet round ${css}: ${seen?.error ?? "never seen"}`);
      break;
    }
    report.stylesheet_rounds_ms.push(r1(pageTime(seen.paint) - write));
    await sleep(300);
  }
  await fs.writeFile(cssAbsolute, cssOriginal);
  await fs.writeFile(absolute, original);

  const e2e = report.rounds.map((round) => round.end_to_end_ms);
  report.target = `webviews/${FILE} (a data attribute on the composer foot), saved in a copy served by Vite dev (webviews/vite.config.ts as \`vp dev\` runs it for cmux live start --worktree), /agent-pane/?mock in ${engine === "webkit" ? "a WKWebView (WebKit, the app's engine)" : "Playwright Chromium"}, React Fast Refresh; save to the next frame after the commit`;
  notes.push(
    `End to end: write() start in this process to the first animation frame after the commit, plus a posted task (the frame's paint ran). p50 ${r1(median(e2e))} ms over ${e2e.length} rounds after ${WARMUP} warm-up saves.`,
    "Stages, by boundary: fs_event = write start to Vite's watcher 'change' (chokidar); hmr_send = watcher 'change' to the page's vite:beforeUpdate (Vite's HMR propagation + socket); transform = the dev server's transformRequest of ComposerFoot.tsx?t= (React Compiler Babel pass, import analysis, Refresh wrapper) from its own timing; apply = the page's module fetch outside that transform (fetchStart to transform start, plus response end to commit: transfer, evaluation, plugin-react's refresh batch, React commit; commit = the MutationObserver callback that sees the probe); paint = commit to the next rAF plus a posted task. unattributed = end to end minus their sum (mostly vite:beforeUpdate to the client's fetch start). detail_ms splits them finer.",
    "Floors: fs_event = node fs.watch (FSEvents on macOS, inotify on Linux) on a fresh directory beside the file, write to callback; hmr_send = half the min-sorted round trips of a custom message over the same HMR socket; transform = environments.client.pluginContainer.transform of the edited text alone (new probe value each time, so the React Compiler cache misses as a save does); apply = in-page import of an already transformed edit (served as a plain module, same module id for Refresh) plus performReactRefresh() called at once, to the commit showing its probe; paint = consecutive rAF deltas (one frame interval).",
    "Graph: transform waits only on fs_event, not on the HMR message: a server can transform the changed module as soon as it sees the change, while the update message is in flight (Vite today transforms only when the page asks, after the message), so apply waits on both and the critical path counts the longer one.",
    "paint's floor is a whole frame interval while the stage is the wait from commit to the next frame (0 to 1 interval): its floor can read above the stage; reported as measured, not clamped.",
    "Vite runs in this process on the same config `vp dev` loads (the timing plugin is added inline), as hot-reload-proof.mjs runs it; CMUX_VITE_TRANSFORM_CACHE is set as web-overlay.sh sets it. Not measured: the cmux app's own webview (a WKWebView host stands in on macOS) and `customize use dir --watch`, which is a different path.",
  );
  if (report.stylesheet_rounds_ms.length)
    notes.push(`Extra stylesheet edit (bottomStack.css custom property): p50 ${r1(median(report.stylesheet_rounds_ms))} ms end to end over ${report.stylesheet_rounds_ms.length} saves.`);
  status.measured = true;
} catch (error) {
  report.error = String(error?.stack ?? error);
  console.error(`web_swap: ${report.error}`);
} finally {
  await cleanup();
}
report.p50_ms = {
  end_to_end: r1(median(report.rounds.map((round) => round.end_to_end_ms))),
  stages: Object.fromEntries(
    ["fs_event", "hmr_send", "transform", "apply", "paint", "unattributed"].map((stage) => [
      stage,
      r1(median(report.rounds.map((round) => round.stages_ms[stage]))),
    ]),
  ),
  floors: Object.fromEntries(Object.entries(report.floors_ms).map(([stage, xs]) => [stage, r1(median(xs))])),
};
await fs.mkdir(path.dirname(outJson), { recursive: true });
await fs.writeFile(outJson, `${JSON.stringify(report, null, 2)}\n`);
console.error(`web_swap: wrote ${outJson}`);
process.exit(status.measured ? 0 : 1);
