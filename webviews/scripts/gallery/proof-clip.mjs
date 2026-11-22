// A PR's proof clip: the changed component rendered by the gallery (the real CSS and theme), light and dark side by
// side, cropped to the component, each named state a row, animations played once at speed and again slowed. No Mac
// and no app launch: headless Chromium on Linux (`cmux-ci test --artifact DIR -- bun run proof:clip ...`).
//
// Leo, 2026-11-22, on a whole-app walkthrough that never showed the change: "these app walkthroughs and shit, you
// guys need to just be stripping this shit down bare into the constituent parts of what the fuck actually matters.
// speed up the walkthrough, consider not even using the fucking macs and just viewing the simulation of our shit
// with the styling with whatever the fuck".
//
//   bun scripts/gallery/proof-clip.mjs --states agent-pane.thinking-look/claude,agent-pane.thinking-look/reduced-motion
//   bun scripts/gallery/proof-clip.mjs --entry agent-pane.thinking-look            # its variants, at most --max-states
//   bun scripts/gallery/proof-clip.mjs --base origin/feat-cmux-next                # the entries the diff touches most
//   options: --out DIR (default $FAST_CHECKS_OUT or proof-clip-out) --clip CSS (crop to it; default the component's
//            painted bounds) --slow 0.35 (the slowed loop's rate) --max-seconds 10 --schemes light,dark
//            --hover CSS (each state again with the pointer on that element: rest, then hover)
//            --before DIR (a checkout of the base, its webviews/ folder: each state rendered there first, as a
//            "before" row over the head's "after"; `git worktree add --detach DIR $(git merge-base HEAD origin/feat-cmux-next)`)
//            --width normal|narrow --max-states 4 --margin 12 --scale 2 --min-cell 560 (a small element is
//            rendered at a higher device scale until its cell is this many pixels wide, up to 8x)
//
// Writes OUT/proof.mp4, OUT/proof.png (the first frame) and OUT/proof.mp4.media.json (the sidecar
// scripts/media/proof_clip_check.py reads: the component's share of the frame, the length, wall seconds), and
// prints the sidecar. Post it with `python3 scripts/pr-media.py --pr N OUT/proof.mp4 --comment` (an mp4 also gets
// its inline gif there).
//
// Motion is sampled, not filmed: every CSS animation and Web Animation on the stage is paused and seeked to each
// frame's time, so the loop is exact on any machine, however slow its renderer. A stage that moves by script alone
// (no Web Animation) is filmed in real time instead, as fast as screenshots come.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { parseArgs } from "node:util";

const started = performance.now();
const { values: args } = parseArgs({
  options: {
    states: { type: "string" },
    entry: { type: "string" },
    base: { type: "string" },
    changed: { type: "string" },
    out: { type: "string" },
    clip: { type: "string" },
    slow: { type: "string", default: "0.35" },
    "max-seconds": { type: "string", default: "10" },
    schemes: { type: "string", default: "light,dark" },
    width: { type: "string", default: "normal" },
    "max-states": { type: "string", default: "4" },
    margin: { type: "string", default: "12" },
    scale: { type: "string", default: "2" },
    fps: { type: "string", default: "30" },
    "min-cell": { type: "string", default: "560" },
    "gallery-dir": { type: "string" },
    hover: { type: "string" },
    before: { type: "string" },
    "before-gallery-dir": { type: "string" },
  },
});

const root = path.resolve(import.meta.dir, "../..");
const repo = path.resolve(root, "..");
const out = path.resolve(args.out ?? process.env.FAST_CHECKS_OUT ?? "proof-clip-out");
fs.mkdirSync(out, { recursive: true });
const work = fs.mkdtempSync(path.join(os.tmpdir(), "proof-clip-"));
const FPS = Number(args.fps);
const SLOW = Number(args.slow);
const MAX_SECONDS = Number(args["max-seconds"]);
const MARGIN = Number(args.margin);
/** The margin round an element: a named one (--clip) keeps a quarter of its short side, at least 3 px, so a tiny
 * element is not lost in its own margin once magnified. */
const marginFor = (box) =>
  args.clip ? Math.min(MARGIN, Math.max(3, Math.round(Math.min(box.width, box.height) / 4))) : MARGIN;
const SCALE = Number(args.scale);
const SCHEMES = args.schemes.split(",").filter(Boolean);
const MAX_STATES = Number(args["max-states"]);
const MIN_CELL = Number(args["min-cell"]);
/** A loop longer than this is cut (a slow ambient pulse would eat the whole clip). */
const MAX_PERIOD_MS = 3000;
const timings = {};
const lap = (name, since) => (timings[name] = Math.round((performance.now() - since) / 10) / 100);

function run(cmd, argv, opts = {}) {
  const result = spawnSync(cmd, argv, { encoding: "utf8", maxBuffer: 64 << 20, ...opts });
  if (result.status !== 0)
    throw new Error(
      `${cmd} ${argv.slice(0, 6).join(" ")} … exited ${result.status}: ${(result.stderr || "").slice(-800)}`,
    );
  return result.stdout;
}

// ------------------------------------------------------------------------------------------- which states
let t0 = performance.now();
/** [{ entry, variant? }]: a missing variant means "the entry's variants". */
let wanted = [];
if (args.states) {
  wanted = args.states.split(",").map((s) => {
    const [entry, variant] = s.trim().split("/");
    return { entry, variant };
  });
} else if (args.entry) {
  wanted = [{ entry: args.entry }];
} else {
  const changed = args.changed
    ? fs.readFileSync(args.changed, "utf8")
    : run("git", ["diff", "--name-only", `${args.base ?? "origin/feat-cmux-next"}...HEAD`], { cwd: repo });
  const list = path.join(work, "changed.txt");
  fs.writeFileSync(list, changed);
  const touched = JSON.parse(run("bun", ["scripts/gallery/touched.ts", "--changed", list], { cwd: root }));
  // The changed component's own entries only (tier 0); a shared stylesheet's far reach is not this PR's proof.
  const own = (touched.ranked ?? []).filter((r) => (r.tier ?? 0) === 0).slice(0, 2);
  if (!own.length) {
    console.error("proof-clip: the change reaches no gallery entry of its own; name one with --entry or --states");
    process.exit(2);
  }
  wanted = own.map((r) => ({ entry: r.id }));
}
const entryIds = [...new Set(wanted.map((w) => w.entry))];
lap("select", t0);

// ------------------------------------------------------------------------------------- build only those entries
t0 = performance.now();
const galleryDir = args["gallery-dir"] ? path.resolve(args["gallery-dir"]) : path.join(work, "gallery");
// --gallery-dir DIR reuses a build there, or builds into it once (a second clip of the same head skips the build).
async function buildGallery(cwd, dir) {
  if (fs.existsSync(path.join(dir, "frame.html"))) return;
  if (!fs.existsSync(path.join(cwd, "node_modules"))) run("bun", ["install", "--frozen-lockfile"], { cwd, stdio: "ignore" });
  await new Promise((resolve, reject) => {
    const build = spawn("bun", ["run", "gallery:build"], {
      cwd,
      stdio: ["ignore", "ignore", "inherit"],
      env: { ...process.env, CMUX_GALLERY_ENTRIES: entryIds.join(","), CMUX_GALLERY_OUT_DIR: dir },
    });
    build.once("error", reject);
    build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build in ${cwd} exited ${code}`))));
  });
}
const beforeRoot = args.before ? path.resolve(args.before) : null;
const beforeDir = beforeRoot ? path.resolve(args["before-gallery-dir"] ?? path.join(work, "gallery-before")) : null;
await Promise.all([buildGallery(root, galleryDir), beforeRoot ? buildGallery(beforeRoot, beforeDir) : null]);
lap("build", t0);

const { preview } = await import("vite");
async function serve(projectRoot, dir) {
  process.env.CMUX_GALLERY_OUT_DIR = dir;
  const server = await preview({
    root: projectRoot,
    configFile: path.join(projectRoot, "vite.config.gallery.ts"),
    build: { outDir: dir },
    preview: { host: "127.0.0.1", port: 0 },
    logLevel: "warn",
  });
  return { server, url: `http://127.0.0.1:${server.httpServer.address().port}` };
}
const after = await serve(root, galleryDir);
const before = beforeRoot ? await serve(beforeRoot, beforeDir) : null;
const baseUrl = after.url;
const { chromium } = await import("playwright");
const browser = await chromium.launch();

// The page's own measure of what to crop to and what moves. Runs in the stage.
function measureStage(clipSelector) {
  const stage = document.getElementById("root") ?? document.body;
  const scope = clipSelector
    ? [...document.querySelectorAll(clipSelector)].find((el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== "hidden";
      })
    : stage;
  if (!scope) return { error: `no element matches ${clipSelector}` };
  const boxes = [];
  const painted = (el) => {
    const cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none" || Number(cs.opacity) === 0) return false;
    const hasText = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
    const media = /^(svg|img|canvas|video|input|textarea|button|select|hr)$/i.test(el.tagName);
    const fill = cs.backgroundColor !== "rgba(0, 0, 0, 0)" && cs.backgroundColor !== "transparent";
    const edge = parseFloat(cs.borderTopWidth) + parseFloat(cs.borderLeftWidth) > 0;
    const image = cs.backgroundImage !== "none" || cs.boxShadow !== "none";
    return hasText || media || fill || edge || image;
  };
  if (clipSelector) boxes.push(scope.getBoundingClientRect());
  else
    for (const el of scope.querySelectorAll("*")) {
      // The stage's own full-size wrappers paint the page background; they are not the component.
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) continue;
      if (r.width >= innerWidth - 1 && r.height >= innerHeight - 1) continue;
      if (painted(el)) boxes.push(r);
    }
  if (!boxes.length) return { error: "the stage painted nothing" };
  const x = Math.min(...boxes.map((b) => b.left));
  const y = Math.min(...boxes.map((b) => b.top));
  const right = Math.max(...boxes.map((b) => b.right));
  const bottom = Math.max(...boxes.map((b) => b.bottom));
  const anims = document.getAnimations().filter((a) => a.playState === "running" || a.playState === "paused");
  const periods = anims.map((a) => {
    const t = a.effect?.getComputedTiming?.() ?? {};
    return Number(t.duration) || 0;
  });
  return {
    box: { x, y, width: right - x, height: bottom - y },
    animations: anims.length,
    periodMs: periods.length ? Math.max(...periods) : 0,
    viewport: { width: innerWidth, height: innerHeight },
  };
}

// --------------------------------------------------------------------------------------------- capture
t0 = performance.now();
/** cells[stateKey][scheme] = { dir, frames, periodMs, box } */
const cells = new Map();
const states = [];

async function openStage(entry, variant, scheme, scale = SCALE, url = baseUrl, hover = null) {
  const context = await browser.newContext({
    viewport: { width: 1040, height: 900 },
    deviceScaleFactor: scale,
    colorScheme: scheme,
    reducedMotion: "no-preference",
  });
  const page = await context.newPage();
  const query = new URLSearchParams({ entry, colorScheme: scheme, width: args.width, frame: "component" });
  if (variant) query.set("variant", variant);
  await page.goto(`${url}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(
    () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
    undefined,
    {
      timeout: 90_000,
    },
  );
  const status = await page.evaluate(() => document.documentElement.dataset.galleryReady);
  if (status !== "1") throw new Error(`${entry}/${variant ?? ""} did not render (${scheme})`);
  if (hover) {
    const target = page.locator(hover).first();
    if (!(await target.count())) throw new Error(`${entry}/${variant ?? ""}: nothing matches --hover ${hover}`);
    await target.hover({ timeout: 10_000 });
    // The hover's own transitions run out before the first frame.
    await page.evaluate(() => Promise.all(document.getAnimations().filter((a) => a.effect?.getComputedTiming?.().iterations !== Infinity).map((a) => a.finished.catch(() => null))));
  }
  // Two frames for the first paint of anything the ready signal raced.
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  return { context, page };
}

async function variantsOf(entry) {
  const { context, page } = await openStage(entry, undefined, SCHEMES[0]);
  const names = await page.evaluate(() => document.documentElement.dataset.galleryVariants ?? "");
  const chosen = await page.evaluate(() => document.documentElement.dataset.galleryVariant ?? "");
  await context.close();
  return names ? names.split(",") : [chosen];
}

for (const w of wanted) {
  if (w.variant) states.push(w);
  else {
    const names = await variantsOf(w.entry).catch(() => []);
    for (const v of names.length ? names : [undefined]) states.push({ entry: w.entry, variant: v });
  }
}
if (states.length > MAX_STATES) {
  console.error(`proof-clip: ${states.length} states; keeping the first ${MAX_STATES} (name them with --states)`);
  states.length = MAX_STATES;
}

const rowsWanted = [];
for (const state of states)
  for (const side of before ? ["before", "after"] : [null])
    for (const hover of args.hover ? [null, args.hover] : [null])
      rowsWanted.push({ ...state, side, hover, url: side === "before" ? before.url : baseUrl });
for (const state of rowsWanted) {
  const key = [state.side, `${state.entry}/${state.variant ?? ""}`, state.hover ? "hover" : null].filter(Boolean).join(" · ");
  const perScheme = {};
  for (const scheme of SCHEMES) {
    let { context, page } = await openStage(state.entry, state.variant, scheme, SCALE, state.url, state.hover);
    let scale = SCALE;
    try {
      let m = await page.evaluate(measureStage, args.clip ?? null);
      if (m.error) throw new Error(`${key} (${scheme}): ${m.error}`);
      // A small element is magnified: rendered (not scaled up) at a device scale that makes its cell MIN_CELL wide.
      const want = Math.min(8, Math.max(SCALE, Math.floor(MIN_CELL / (m.box.width + 2 * marginFor(m.box)))));
      if (want > scale) {
        await context.close();
        scale = want;
        ({ context, page } = await openStage(state.entry, state.variant, scheme, scale, state.url, state.hover));
        m = await page.evaluate(measureStage, args.clip ?? null);
        if (m.error) throw new Error(`${key} (${scheme}): ${m.error}`);
      }
      const box = m.box;
      const margin = marginFor(box);
      const clip = {
        x: Math.max(0, Math.floor(box.x - margin)),
        y: Math.max(0, Math.floor(box.y - margin)),
      };
      clip.width = Math.min(m.viewport.width - clip.x, Math.ceil(box.width + 2 * margin));
      clip.height = Math.min(m.viewport.height - clip.y, Math.ceil(box.height + 2 * margin));
      const dir = path.join(work, "cells", key.replace(/[^\w.-]+/g, "_"), scheme);
      fs.mkdirSync(dir, { recursive: true });
      let frames = 1;
      let periodMs = 0;
      let mode = "still";
      if (m.animations && m.periodMs > 0) {
        // Seek every animation to each frame's time: an exact loop, whatever the renderer's speed.
        periodMs = Math.min(MAX_PERIOD_MS, m.periodMs);
        frames = Math.max(2, Math.round((periodMs / 1000) * FPS));
        mode = "seeked";
        await page.evaluate(() => document.getAnimations().forEach((a) => a.pause()));
        const origin = await page.evaluate(() => document.getAnimations().map((a) => Number(a.currentTime) || 0));
        for (let i = 0; i < frames; i++) {
          const t = (i * periodMs) / frames;
          await page.evaluate(
            ([t, origin]) =>
              document.getAnimations().forEach((a, k) => {
                a.currentTime = (origin[k] ?? 0) + t;
              }),
            [t, origin],
          );
          await page.screenshot({ path: path.join(dir, `${String(i).padStart(4, "0")}.png`), clip });
        }
      } else {
        // No Web Animation: film it for a moment and keep the frames only when the picture moves.
        const first = await page.screenshot({ clip });
        fs.writeFileSync(path.join(dir, "0000.png"), first);
        const filmMs = 1500;
        const t = performance.now();
        const shots = [];
        while (performance.now() - t < filmMs) shots.push(await page.screenshot({ clip }));
        if (shots.some((s) => !s.equals(first))) {
          mode = "filmed";
          periodMs = filmMs;
          shots.forEach((s, i) => fs.writeFileSync(path.join(dir, `${String(i + 1).padStart(4, "0")}.png`), s));
          frames = shots.length + 1;
        }
      }
      perScheme[scheme] = { dir, frames, periodMs, mode, clip, element: box, scale };
    } finally {
      await page.context().close();
    }
  }
  cells.set(key, perScheme);
}
lap("capture", t0);

// ------------------------------------------------------------------------------------------- compose
t0 = performance.now();
const allCells = [...cells.values()].flatMap((s) => Object.values(s));
const cellW = Math.max(...allCells.map((c) => c.clip.width * c.scale));
const cellH = Math.max(...allCells.map((c) => c.clip.height * c.scale));
const even = (n) => (Math.ceil(n) + 1) & ~1;
const PW = even(cellW);
const PH = even(cellH);
const LABEL_H = Math.round(18 * SCALE) & ~1;
const GAP = Math.round(4 * SCALE) & ~1;
const animated = [...cells.values()].some((s) => Object.values(s).some((c) => c.frames > 1));
const longest = Math.max(0, ...[...cells.values()].flatMap((s) => Object.values(s).map((c) => c.periodMs)));
// One pass at speed (at least one full loop, at least 1.5 s), then the slowed loop in what is left of the budget.
const fastSeconds = animated ? Math.min(3, Math.max(1.5, longest / 1000)) : 2;
const slowSeconds = animated ? Math.max(0, Math.min(longest / 1000 / SLOW, MAX_SECONDS - fastSeconds)) : 0;

async function labelPng(text, width, height, file, align = "left") {
  const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await page.setContent(
    `<body style="margin:0;background:#1d1d1f;color:#f5f5f7;font:600 ${Math.round(height * 0.62)}px -apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:${align === "left" ? "flex-start" : "center"};padding:0 ${GAP}px;height:${height}px;white-space:nowrap;overflow:hidden">${text.replace(/</g, "&lt;")}</body>`,
  );
  // Shrink the words until they fit the band (a narrow clip keeps its whole title).
  await page.evaluate(() => {
    const body = document.body;
    let size = parseFloat(getComputedStyle(body).fontSize);
    while (body.scrollWidth > innerWidth && size > 8) body.style.fontSize = `${(size -= 1)}px`;
  });
  await page.screenshot({ path: file });
  await context.close();
}

/** A state's name as a small pill drawn over its first cell's corner, so names take no band of the frame. */
async function pillPng(text, file) {
  const context = await browser.newContext({ viewport: { width: W, height: LABEL_H * 2 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await page.setContent(
    `<body style="margin:0;background:transparent"><span id="p" style="display:inline-block;background:rgba(29,29,31,.78);color:#f5f5f7;font:600 ${Math.round(LABEL_H * 0.5)}px -apple-system,system-ui,sans-serif;padding:${GAP / 2}px ${GAP * 1.5}px;border-bottom-right-radius:${GAP * 1.5}px;white-space:nowrap">${text.replace(/</g, "&lt;")}</span></body>`,
  );
  await page.locator("#p").screenshot({ path: file, omitBackground: true });
  await context.close();
}

const W = SCHEMES.length * PW + (SCHEMES.length - 1) * GAP;
const rows = [...cells.keys()];
const H = LABEL_H + rows.length * (PH + GAP);

async function segment(rate, seconds, file, tag) {
  const header = path.join(work, `header-${tag}.png`);
  const headerText =
    `${entryIds.join(", ")}   ·   ${SCHEMES.join(" | ")}` +
    (animated ? `   ·   ${rate === 1 ? "1x" : `${rate}x slowed`}` : "");
  await labelPng(headerText, W, LABEL_H, header, "center");
  const inputs = ["-loop", "1", "-framerate", String(FPS), "-i", header];
  const filters = [];
  const layout = [];
  let n = 1;
  let y = LABEL_H + GAP;
  for (const key of rows) {
    const label = path.join(work, `label-${n}.png`);
    // The entry is in the clip's title; a row is named by its variant.
    await pillPng(entryIds.length === 1 ? key.replace(`${entryIds[0]}/`, "") : key, label);
    const labelInput = n++;
    inputs.push("-loop", "1", "-framerate", String(FPS), "-i", label);
    SCHEMES.forEach((scheme, s) => {
      const c = cells.get(key)[scheme];
      if (c.frames > 1) {
        // The cell's own loop: its frames span its period; at `rate` each frame lasts longer.
        const fr = (c.frames / (c.periodMs / 1000)) * rate;
        inputs.push("-stream_loop", "-1", "-framerate", fr.toFixed(4), "-i", path.join(c.dir, "%04d.png"));
      } else inputs.push("-loop", "1", "-framerate", String(FPS), "-i", path.join(c.dir, "0000.png"));
      filters.push(
        `[${n}:v]fps=${FPS},scale=w='min(iw,${PW})':h='min(ih,${PH})':force_original_aspect_ratio=decrease,pad=${PW}:${PH}:(ow-iw)/2:(oh-ih)/2:color=0x808080[c${n}]`,
      );
      layout.push({ input: n++, x: s * (PW + GAP), y, cell: true });
    });
    layout.push({ input: labelInput, x: 0, y });
    y += PH + GAP;
  }
  // A plain canvas, then every piece overlaid at its place.
  let chain = `color=c=0x2a2a2c:s=${W}x${H}:r=${FPS}:d=${seconds}[bg0];[0:v]fps=${FPS}[h0];[bg0][h0]overlay=0:0:shortest=1[bg1]`;
  let last = "bg1";
  let k = 2;
  for (const piece of layout) {
    const src = piece.cell ? `c${piece.input}` : `${piece.input}:v`;
    chain += `;[${last}][${src}]overlay=${piece.x}:${piece.y}:eof_action=repeat[bg${k}]`;
    last = `bg${k++}`;
  }
  const graph = [...filters, chain].join(";");
  run("ffmpeg", [
    "-nostdin",
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    ...inputs,
    "-filter_complex",
    graph,
    "-map",
    `[${last}]`,
    "-t",
    seconds.toFixed(3),
    "-r",
    String(FPS),
    "-c:v",
    "libx264",
    "-pix_fmt",
    "yuv420p",
    "-crf",
    "18",
    "-preset",
    "veryfast",
    file,
  ]);
}

const parts = [];
await segment(1, fastSeconds, path.join(work, "fast.mp4"), "fast");
parts.push(path.join(work, "fast.mp4"));
if (slowSeconds > 0.2) {
  await segment(SLOW, slowSeconds, path.join(work, "slow.mp4"), "slow");
  parts.push(path.join(work, "slow.mp4"));
}
const clipFile = path.join(out, "proof.mp4");
const list = path.join(work, "parts.txt");
fs.writeFileSync(list, parts.map((p) => `file '${p}'`).join("\n"));
run("ffmpeg", [
  "-nostdin",
  "-loglevel",
  "error",
  "-y",
  "-f",
  "concat",
  "-safe",
  "0",
  "-i",
  list,
  "-c",
  "copy",
  "-movflags",
  "+faststart",
  clipFile,
]);
run("ffmpeg", ["-nostdin", "-loglevel", "error", "-y", "-i", clipFile, "-frames:v", "1", path.join(out, "proof.png")]);
lap("compose", t0);

await browser.close();
for (const s of [after, before].filter(Boolean)) await new Promise((resolve) => s.server.httpServer.close(() => resolve()));

// ------------------------------------------------------------------------------------------- sidecar
const duration = Number(
  run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", clipFile]).trim(),
);
// The component's share of the frame: each cell's painted element (not its margin, not the labels) over the whole.
const elementArea = allCells.reduce((sum, c) => sum + c.element.width * c.scale * (c.element.height * c.scale), 0);
const sidecar = {
  tool: "webviews/scripts/gallery/proof-clip.mjs",
  source: "gallery",
  states: rows,
  schemes: SCHEMES,
  dims: [W, H],
  duration_s: Math.round(duration * 100) / 100,
  element_coverage: Math.round((elementArea / (W * H)) * 1000) / 1000,
  slowed_rate: slowSeconds > 0.2 ? SLOW : null,
  cells: Object.fromEntries(
    [...cells].map(([key, s]) => [
      key,
      Object.fromEntries(
        Object.entries(s).map(([scheme, c]) => [
          scheme,
          { mode: c.mode, frames: c.frames, period_ms: c.periodMs, crop: c.clip, scale: c.scale },
        ]),
      ),
    ]),
  ),
  wall_seconds: Math.round((performance.now() - started) / 100) / 10,
  phases: timings,
};
fs.writeFileSync(`${clipFile}.media.json`, `${JSON.stringify(sidecar, null, 2)}\n`);
fs.rmSync(work, { recursive: true, force: true });
console.log(JSON.stringify(sidecar));
