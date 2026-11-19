// l10n-allow-file: bench fixture text, not shipped UI.
// What one frame of web glass costs on the GPU, the lens as it ships against the glass engine
// (src/ui/glass/engine), in one harness: a page over a wallpaper still with the art's blur, a
// composer, a menu and CHIPS small glass (the chips and pills of a busy pane), at each SIZES
// viewport. Per renderer, glass mode (lens, spectrum), art blur, size and glass count:
//   cost   ROUNDS x BATCH (120) frames drawn back to back with one readback after the last, so the GPU
//          finished them all (glassLensDrawCost): p50 / p95 / p99 of the per-frame ms, and how many
//          panes redrawing in the same frame fit a 120 Hz frame (8.33 ms) at p95.
//   paced  every glass moving (a CSS animation), so the lens redraws every frame: PACED animation
//          frame intervals after 60 warm-up, p50 / p95 / max, fps, dropped frames (an interval over
//          1.5x the refresh read with nothing moving) and lens draws per frame.
//   bun bench/glass-engine.bench.ts [rounds=20]
// Defaults: SIZES=1440x900@2,1920x1080@2 (1920x1080 at 2x is 3840x2160 device px), CHIPS=1,30 (3 and 32
// glass), MODES=lens:0,lens:24,spectrum:24, PACED=600 (0 skips it). LABEL names the run; OUT=path writes
// every row as JSON.
// BROWSER: chromium (default off a Mac) and webkit launch through bench/browsers.ts (Playwright).
//   chrome (default on a Mac) starts the installed Google Chrome itself (CHROME=path), a fresh profile and
//   no automation attached (no Playwright on Macs, Lawrence 2026-11-02), on the GPU (ANGLE on Metal);
//   CHROME_MODE=headless (default: the viewport is exactly SIZES whatever the screen) or headful (the
//   display's own refresh paces the frames; the window may be clipped to the screen, see device px).
// Every case page runs by itself and posts its row to this bench's server, then goes to the next.
// The WebGL renderer string is printed per row; SwiftShader or llvmpipe is flagged as software.
// The fleet runs it through scripts/measure/glass-engine-frames.sh.
/// <reference types="bun" />
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit } from "./browsers";

const ROUNDS = Number(process.argv.slice(2).find((arg) => !arg.startsWith("-")) ?? 20);
const CHIPS = (process.env.CHIPS ?? process.env.GLASS ?? "1,30").split(",").map(Number);
const SIZES = (process.env.SIZES ?? "1440x900@2,1920x1080@2").split(",").map((size) => {
  const match = /^(\d+)x(\d+)@(\d+(?:\.\d+)?)$/.exec(size.trim());
  if (!match) throw new Error(`SIZES: ${size} is not WIDTHxHEIGHT@DPR`);
  return { width: Number(match[1]), height: Number(match[2]), dpr: Number(match[3]) };
});
const MODES = (process.env.MODES ?? "lens:0,lens:24,spectrum:24").split(",").map((pair) => {
  const [mode, blur] = pair.split(":");
  return { mode: mode!, blur: Number(blur ?? 0) };
});
const PACED = Number(process.env.PACED ?? 600);
const BATCH = Number(process.env.BATCH ?? 120);
const BROWSER =
  process.env.BROWSER ??
  (process.platform === "darwin" && process.env.GITHUB_ACTIONS !== "true" ? "chrome" : "chromium");
const CHROME_MODE = process.env.CHROME_MODE ?? "headless";
const LABEL = process.env.LABEL ?? "run";
const CASE_TIMEOUT_MS = Number(process.env.CASE_TIMEOUT_MS ?? 10 * 60_000);
if (!["chrome", "chromium", "webkit"].includes(BROWSER))
  throw new Error(`BROWSER=${BROWSER}: chrome, chromium or webkit`);
if (!["headless", "headful"].includes(CHROME_MODE)) throw new Error(`CHROME_MODE=${CHROME_MODE}: headless or headful`);
const source = path.resolve(import.meta.dir, "../src");
const log = (...args: unknown[]) => console.error("glass-engine:", ...args);

const css = ["pages/shared/desktop.css", "ui/glass/glass.css"]
  .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
  .join("\n");
const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glass-engine-bench-")), "entry.ts");
fs.writeFileSync(
  entry,
  `import { installGlassLens, glassLensState, glassLensDrawCost } from ${JSON.stringify(path.join(source, "ui/glass/lens.ts"))};
   Object.assign(window, { installGlassLens, glassLensState, glassLensDrawCost });`,
);
const built = await Bun.build({ entrypoints: [entry], target: "browser" });
if (!built.success) throw new Error(built.logs.join("\n"));
const script = await built.outputs[0]!.text();
fs.rmSync(path.dirname(entry), { recursive: true, force: true });
const wallpaper = fs.readFileSync(path.join(source, "gallery/fixtures/assets/liquid-glass-wallpaper.jpg"));

type Case = {
  index: number;
  group: number;
  engine: boolean;
  mode: string;
  blur: number;
  chips: number;
  width: number;
  height: number;
  dpr: number;
};
const cases: Case[] = [];
SIZES.forEach((size, group) => {
  for (const chips of CHIPS)
    for (const { mode, blur } of MODES)
      for (const engine of [false, true])
        cases.push({ index: cases.length, group, engine, mode, blur, chips, ...size });
});

const chipsHtml = (count: number) =>
  Array.from(
    { length: count },
    (_, i) =>
      `<div class="ui-glass" style="position:absolute;left:${24 + (i % 10) * 138}px;top:${150 + Math.floor(i / 10) * 70}px;width:120px;height:48px;border-radius:${i % 3 ? 12 : 24}px"></div>`,
  ).join("");

/// The case's page measures itself in the browser: no automation drives it.
function runner(one: Case, rounds: number, paced: number, batch: number) {
  const host = window as unknown as {
    installGlassLens(doc: Document): void;
    glassLensDrawCost(doc?: Document, count?: number): number | null;
    glassLensState(doc?: Document): { drawing: boolean; engine: boolean; rects: number; draws: number } | null;
    cmuxTheme: { backdrop(partial: unknown): void };
  };
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  const intervals = async (count: number) => {
    const out: number[] = [];
    let last = await frame();
    for (let i = 0; i < count; i++) {
      const now = await frame();
      out.push(now - last);
      last = now;
    }
    return out;
  };
  const run = async () => {
    const image = `${location.origin}/wallpaper.jpg`;
    document.documentElement.style.setProperty(
      "background",
      `url(${image}) 0 0 / 100vw 100vh no-repeat fixed`,
      "important",
    );
    host.installGlassLens(document);
    host.cmuxTheme.backdrop({
      image,
      key: "bench",
      rect: { x: 0, y: 0, width: innerWidth, height: innerHeight },
      blur: one.blur,
      tint: "rgba(0,0,0,0.18)",
    });
    for (let i = 0; i < 40; i++) await frame();
    for (let i = 0; i < 200 && !host.glassLensState(document)?.drawing; i++) await frame();
    const gl = document.createElement("canvas").getContext("webgl");
    const info = gl?.getExtension("WEBGL_debug_renderer_info");
    const gpu = info && gl ? String(gl.getParameter(info.UNMASKED_RENDERER_WEBGL)) : "unknown";
    const state = host.glassLensState(document);
    if (!state?.drawing || state.engine !== one.engine)
      throw new Error(`not drawing as asked: ${JSON.stringify(state)}`);
    host.glassLensDrawCost(document, 20);
    const cost: number[] = [];
    for (let round = 0; round < rounds; round++) cost.push(host.glassLensDrawCost(document, batch) ?? Number.NaN);
    // The refresh with nothing moving (the lens settles and stops drawing), then every glass moving.
    for (let i = 0; i < 30; i++) await frame();
    const idle = paced > 0 ? await intervals(120) : [];
    let moving: number[] = [];
    let draws = 0;
    if (paced > 0) {
      document.documentElement.classList.add("bench-moving");
      for (let i = 0; i < 60; i++) await frame();
      const before = host.glassLensState(document)?.draws ?? 0;
      moving = await intervals(paced);
      draws = (host.glassLensState(document)?.draws ?? 0) - before;
      document.documentElement.classList.remove("bench-moving");
    }
    return {
      gpu,
      glass: state.rects,
      device: `${Math.round(innerWidth * devicePixelRatio)}x${Math.round(innerHeight * devicePixelRatio)}`,
      dpr: devicePixelRatio,
      cost,
      idle,
      moving,
      draws,
    };
  };
  void (async () => {
    let body: unknown;
    try {
      body = await run();
    } catch (error) {
      body = { error: String((error as Error)?.stack ?? error) };
    }
    const answer = await fetch(`/result/${one.index}`, { method: "POST", body: JSON.stringify(body) });
    const { next } = (await answer.json()) as { next: string | null };
    location.href = next ?? "/done";
  })();
}

const html = (one: Case) =>
  `<!doctype html><html data-glass="${one.mode}" ${one.engine ? "data-glass-engine" : ""} style="--cmux-surface-background:transparent;--cmux-surface-solid:rgb(30,31,36);--cmux-text:rgb(236,236,240)">
   <head><style>${css} body{margin:0}
   @keyframes bench-sway { to { translate: 24px 12px; } }
   .bench-moving .ui-glass { animation: bench-sway 0.9s ease-in-out infinite alternate; }</style></head><body>
   <div class="ui-glass" style="position:absolute;right:60px;top:30px;width:220px;height:150px;border-radius:12px"></div>
   ${chipsHtml(one.chips)}
   <div class="ui-glass" style="position:absolute;left:28px;right:28px;bottom:28px;height:120px;border-radius:22px"></div>
   <script src="/lens.js"></script>
   <script>(${runner.toString()})(${JSON.stringify(one)}, ${ROUNDS}, ${PACED}, ${BATCH});</script>
   </body></html>`;

type Raw = {
  error?: string;
  gpu: string;
  glass: number;
  device: string;
  dpr: number;
  cost: number[];
  idle: number[];
  moving: number[];
  draws: number;
};
const raws = new Map<number, Raw>();
let groupDone: (() => void) | null = null;
const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname === "/lens.js") return new Response(script, { headers: { "content-type": "text/javascript" } });
    if (pathname === "/wallpaper.jpg") return new Response(wallpaper, { headers: { "content-type": "image/jpeg" } });
    if (pathname === "/done") return new Response("<!doctype html><title>done</title>", { headers: { "content-type": "text/html" } }); // prettier-ignore
    const page = /^\/case\/(\d+)$/.exec(pathname);
    if (page) {
      const one = cases[Number(page[1])];
      return one ? new Response(html(one), { headers: { "content-type": "text/html" } }) : new Response("no case", { status: 404 }); // prettier-ignore
    }
    const result = /^\/result\/(\d+)$/.exec(pathname);
    if (result && request.method === "POST") {
      const index = Number(result[1]);
      const raw = JSON.parse(await request.text()) as Raw;
      raws.set(index, raw);
      const one = cases[index]!;
      log(`${index + 1}/${cases.length} ${one.engine ? "engine" : "lens"} ${one.mode}:${one.blur} ${one.width}x${one.height}@${one.dpr} chips=${one.chips}${raw.error ? ` FAILED ${raw.error.split("\n")[0]}` : ""}`); // prettier-ignore
      const next = cases[index + 1];
      const more = next && next.group === one.group;
      if (!more) setTimeout(() => groupDone?.(), 0);
      return Response.json({ next: more ? `/case/${next.index}` : null });
    }
    return new Response("not found", { status: 404 });
  },
});
const origin = `http://127.0.0.1:${server.port}`;

/// Waits until every case of the group posted, or the group's time ran out.
function groupFinished(count: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no result in ${CASE_TIMEOUT_MS * count} ms`)), CASE_TIMEOUT_MS * count); // prettier-ignore
    groupDone = () => {
      clearTimeout(timer);
      resolve();
    };
  });
}

const CHROME_ARGS = [
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-extensions",
  "--disable-component-update",
  "--disable-sync",
  "--use-mock-keychain",
  "--password-store=basic",
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--disable-backgrounding-occluded-windows",
];
const GPU_ARGS = process.platform === "darwin" ? ["--enable-gpu", "--use-angle=metal", "--ignore-gpu-blocklist"] : [];

async function chromeVersion(binary: string): Promise<string> {
  return new Promise((resolve) => {
    const child = spawn(binary, ["--version"], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (chunk) => (out += chunk));
    child.on("exit", () => resolve(out.trim()));
    child.on("error", () => resolve(""));
  });
}

let browserName = BROWSER;
const groups = SIZES.map((size, group) => ({ size, cases: cases.filter((one) => one.group === group) }));
try {
  if (BROWSER === "chrome") {
    const binary =
      process.env.CHROME ??
      (process.platform === "darwin"
        ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        : "google-chrome");
    if (path.isAbsolute(binary) && !fs.existsSync(binary)) throw new Error(`no Chrome at ${binary} (set CHROME=path)`);
    browserName = `${(await chromeVersion(binary)) || binary} ${CHROME_MODE}`;
    for (const { size, cases: group } of groups) {
      const profile = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "glass-engine-chrome-"));
      const args = [
        `--user-data-dir=${profile}`,
        ...CHROME_ARGS,
        ...GPU_ARGS,
        ...(CHROME_MODE === "headless" ? ["--headless=new"] : ["--new-window", "--window-position=0,0"]),
        `--window-size=${size.width},${size.height}`,
        `--force-device-scale-factor=${size.dpr}`,
        `${origin}/case/${group[0]!.index}`,
      ];
      const child = spawn(binary, args, { stdio: ["ignore", "ignore", "pipe"] });
      let stderr = "";
      child.stderr?.on("data", (chunk) => void (stderr = (stderr + chunk).slice(-4000)));
      const exited = new Promise<never>((_, reject) =>
        child.on("exit", (code, signal) => reject(new Error(`Chrome exited (${code ?? signal}) mid-run\n${stderr}`))),
      );
      try {
        await Promise.race([groupFinished(group.length), exited]);
      } finally {
        // Only the Chrome this bench started, by its pid; then the profile this bench made.
        if (child.exitCode === null && child.pid) {
          child.kill("SIGTERM");
          await new Promise((resolve) => setTimeout(resolve, 2000));
          if (child.exitCode === null) child.kill("SIGKILL");
        }
        fs.rmSync(profile, { recursive: true, force: true });
      }
    }
  } else {
    const type = BROWSER === "webkit" ? webkit : chromium;
    const browser = await type.launch({ headless: true, args: BROWSER === "webkit" ? [] : GPU_ARGS });
    browserName = `${BROWSER} ${browser.version()}`;
    try {
      for (const { size, cases: group } of groups) {
        const page = await browser.newPage({
          viewport: { width: size.width, height: size.height },
          deviceScaleFactor: size.dpr,
        });
        page.on("pageerror", (error) => log(`page error: ${error.message}`));
        const finished = groupFinished(group.length);
        await page.goto(`${origin}/case/${group[0]!.index}`);
        await finished;
        await page.close();
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await server.stop(true);
}

function percentile(values: number[], p: number): number {
  if (values.length === 0) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
}
const round3 = (value: number) => (Number.isFinite(value) ? +value.toFixed(3) : null);

const host = os.hostname();
const results: Record<string, unknown>[] = [];
for (const one of cases) {
  const raw = raws.get(one.index);
  if (!raw || raw.error) {
    results.push({ label: LABEL, renderer: one.engine ? "engine" : "lens", mode: one.mode, error: raw?.error ?? "no result" }); // prettier-ignore
    continue;
  }
  const p95 = percentile(raw.cost, 95);
  const refresh = percentile(raw.idle, 50);
  const mean = raw.moving.reduce((sum, value) => sum + value, 0) / Math.max(1, raw.moving.length);
  results.push({
    label: LABEL,
    browser: browserName,
    host,
    gpu: raw.gpu,
    software: /swiftshader|llvmpipe|softpipe|software/i.test(raw.gpu),
    renderer: one.engine ? "engine" : "lens",
    mode: one.mode,
    artBlur: one.blur,
    glass: raw.glass,
    viewport: `${one.width}x${one.height}@${one.dpr}`,
    device: raw.device,
    p50: round3(percentile(raw.cost, 50)),
    p95: round3(p95),
    p99: round3(percentile(raw.cost, 99)),
    panesAt120Hz: Math.floor(8.33 / p95),
    refreshMs: round3(refresh),
    frameP50: round3(percentile(raw.moving, 50)),
    frameP95: round3(percentile(raw.moving, 95)),
    frameMax: round3(raw.moving.length ? Math.max(...raw.moving) : Number.NaN),
    fps: round3(raw.moving.length ? 1000 / mean : Number.NaN),
    dropped: raw.moving.filter((ms) => ms > 1.5 * refresh).length,
    frames: raw.moving.length,
    drawsPerFrame: round3(raw.moving.length ? raw.draws / raw.moving.length : Number.NaN),
  });
}

const first = results.find((row) => row.gpu) as { gpu?: string; software?: boolean } | undefined;
console.error(`glass-engine: ${browserName} on ${host}; WebGL renderer: ${first?.gpu ?? "?"}`);
if (first?.software) console.error("glass-engine: SOFTWARE GL: a smoke test, not a GPU number");
const f = (value: unknown, width: number) => String(value ?? "-").padStart(width);
console.error("renderer mode:blur  glass viewport       device      cost p50   p95   p99 | frame p50   p95    max   fps dropped draws/f"); // prettier-ignore
for (const row of results as Record<string, any>[]) {
  if (row.error) {
    console.error(`${String(row.renderer).padEnd(8)} ${row.mode} FAILED: ${String(row.error).split("\n")[0]}`);
    continue;
  }
  console.error(
    `${row.renderer.padEnd(8)} ${`${row.mode}:${row.artBlur}`.padEnd(11)} ${f(row.glass, 5)} ${row.viewport.padEnd(14)} ${row.device.padEnd(10)} ${f(row.p50, 8)} ${f(row.p95, 5)} ${f(row.p99, 5)} | ${f(row.frameP50, 9)} ${f(row.frameP95, 5)} ${f(row.frameMax, 6)} ${f(row.fps, 5)} ${f(`${row.dropped}/${row.frames}`, 7)} ${f(row.drawsPerFrame, 7)}`, // prettier-ignore
  );
}
if (process.env.OUT) {
  fs.mkdirSync(path.dirname(path.resolve(process.env.OUT)), { recursive: true });
  fs.writeFileSync(process.env.OUT, JSON.stringify(results, null, 2));
}
console.log(JSON.stringify(results, null, 2));
