// A PR's proof clip: the changed component rendered by the gallery (the real CSS and theme), light and dark side by
// side, cropped to the component, each named state a row, animations played once at speed and again slowed. No Mac
// and no app launch: headless Chromium on Linux (`cmux-ci test --artifact DIR -- bun run proof:clip ...`).
//
// Leo, 2026-11-22, on a whole-app walkthrough that never showed the change: "these app walkthroughs and shit, you
// guys need to just be stripping this shit down bare into the constituent parts of what the fuck actually matters.
// speed up the walkthrough, consider not even using the fucking macs and just viewing the simulation of our shit
// with the styling with whatever the fuck". And at 07:20: "i need to see the actual relevant bit. ... you cant be
// spending a lot of time setting up and recording videos and shit. these all need to be ultra fast. and higher
// quality if possible. faster, better visuals."
//
// So: no build. The first clip starts proof-clip-server.mjs (the gallery's Vite dev server compiled with Oxc, about
// 10 s cold) and leaves it up for --idle minutes; every clip after that reuses it and takes about 8 s (the
// agent-pane dots: about 15 s cold, where the old build-then-film tool took 123 s). Each cell is rendered at a
// device scale of up to --max-scale until it is --min-cell pixels wide, written losslessly, then encoded once at
// crf 12 (mp4) and with a full palette (gif): crisp text, no mush. The sidecar records the wall time of each
// phase; over --budget seconds the tool says which phase was slow.
//
//   bun scripts/gallery/proof-clip.mjs --states agent-pane.thinking-look/claude,agent-pane.thinking-look/reduced-motion
//   bun scripts/gallery/proof-clip.mjs --entry agent-pane.thinking-look            # its variants, at most --max-states
//   bun scripts/gallery/proof-clip.mjs --base origin/feat-cmux-next                # the entries the diff touches most
//   options: --out DIR (default $FAST_CHECKS_OUT or proof-clip-out) --clip CSS (crop to it; default the component's
//            painted bounds) --slow 0.35 (the slowed loop's rate) --max-seconds 10 --schemes light,dark
//            --hover CSS (each state again with the pointer on that element: rest, then hover)
//            --before DIR (a checkout of the base, its webviews/ folder: each state rendered there first, as a
//            "before" row over the head's "after"; `git worktree add --detach DIR $(git merge-base HEAD origin/feat-cmux-next)`)
//            --width normal|narrow --max-states 4 --margin 12 --scale 2 --min-cell 640 (a small element is
//            rendered at a higher device scale until its cell is this many pixels wide, up to --max-scale 16)
//            --budget 20 (seconds) --keep 1 (0 stops a server this run started) --idle 20 (minutes)
//            --compiler oxc|babel
//
// Writes OUT/proof.mp4, OUT/proof.png (the first frame) and OUT/proof.mp4.media.json (the sidecar
// scripts/media/proof_clip_check.py reads: the component's share of the frame, the length, wall seconds), and
// prints the sidecar. Post it with `python3 scripts/pr-media.py --pr N OUT/proof.mp4 --comment` (an mp4 also gets
// its inline gif there).
//
// Motion is sampled, not filmed: every CSS animation and Web Animation on the stage is paused and seeked to each
// frame's time, so the loop is exact on any machine, however slow its renderer. A stage that moves by script alone
// (no Web Animation) is filmed in real time instead, as fast as screenshots come.
import { createHash } from "node:crypto";
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
    "min-cell": { type: "string", default: "640" },
    hover: { type: "string" },
    before: { type: "string" },
    at: { type: "string" },
    compiler: { type: "string", default: "oxc" },
    keep: { type: "string", default: "1" },
    idle: { type: "string", default: "20" },
    budget: { type: "string", default: "20" },
    "max-scale": { type: "string", default: "16" },
  },
});

/** This checkout's webviews/: the tool, its dependencies. */
const toolRoot = path.resolve(import.meta.dir, "../..");
const repo = path.resolve(toolRoot, "..");
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
const MAX_SCALE = Number(args["max-scale"]);
/** A loop longer than this is cut (a slow ambient pulse would eat the whole clip). */
const MAX_PERIOD_MS = 3000;
const timings = {};
const lap = (name, since) => (timings[name] = Math.round((performance.now() - since) / 10) / 100);

function runAsync(cmd, argv) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, argv, { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    child.stderr.on("data", (d) => (err += d));
    child.once("error", reject);
    child.once("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`${cmd} ${argv.slice(0, 6).join(" ")} … exited ${code}: ${err.slice(-800)}`)),
    );
  });
}

function run(cmd, argv, opts = {}) {
  const result = spawnSync(cmd, argv, { encoding: "utf8", maxBuffer: 64 << 20, ...opts });
  if (result.status !== 0)
    throw new Error(
      `${cmd} ${argv.slice(0, 6).join(" ")} … exited ${result.status}: ${(result.stderr || "").slice(-800)}`,
    );
  return result.stdout;
}

/** A checkout ready to render: its dependencies (linked from this one's when the lockfiles match) and its generated
 *  strings and theme, which the gallery's modules import. Once per checkout; seconds after the first. */
const prepared = new Set();
function prepare(projectRoot) {
  if (prepared.has(projectRoot)) return;
  prepared.add(projectRoot);
  if (!fs.existsSync(path.join(projectRoot, "node_modules"))) {
    // A throwaway checkout (a PR's head, --before's base) with this one's lockfile borrows its node_modules: a link,
    // not a minute of bun install.
    const lock = (dir) => fs.readFileSync(path.join(dir, "bun.lock"), "utf8");
    if (projectRoot !== toolRoot && lock(projectRoot) === lock(toolRoot))
      fs.symlinkSync(path.join(toolRoot, "node_modules"), path.join(projectRoot, "node_modules"), "dir");
    else run("bun", ["install", "--frozen-lockfile"], { cwd: projectRoot, stdio: "ignore" });
  }
  // Only what is missing or older than its inputs: 70 ms when nothing is.
  run("node", ["scripts/pages/gen-strings.mjs", "--if-stale"], { cwd: projectRoot, stdio: "ignore" });
}

// ------------------------------------------------------------------------------------------- which states
/** The webviews/ of REF's tree, checked out once (sparse: what the gallery reads, ~140 MB, a few seconds) and reused:
 *  another commit is rendered without a checkout of its own (--at, --before). A folder is used as it is. */
function treeAt(ref) {
  if (fs.existsSync(path.join(ref, "package.json"))) return path.resolve(ref);
  if (fs.existsSync(path.join(ref, "webviews/package.json"))) return path.resolve(ref, "webviews");
  const resolve = () =>
    spawnSync("git", ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], {
      cwd: repo,
      encoding: "utf8",
    }).stdout.trim();
  let sha = resolve();
  if (!sha) {
    run("git", ["fetch", "--quiet", "origin", ref], { cwd: repo });
    sha = resolve() || run("git", ["rev-parse", "FETCH_HEAD"], { cwd: repo }).trim();
  }
  const dir = path.join(os.homedir(), ".cache/proof-clip/trees", sha.slice(0, 12));
  if (!fs.existsSync(path.join(dir, "webviews/package.json"))) {
    fs.rmSync(dir, { recursive: true, force: true });
    run("git", ["worktree", "prune"], { cwd: repo });
    run("git", ["worktree", "add", "--quiet", "--no-checkout", "--detach", dir, sha], { cwd: repo });
    // Everything the gallery's modules and gen-strings read outside webviews/.
    run(
      "git",
      ["sparse-checkout", "set", "--no-cone"].concat(
        ["/webviews/", "/release-notes/", "/schemas/", "/design/icons/", "/first-party-apps/", "/web/data/"],
        ["/Packages/Shared/CmuxAgentQuestion/", "/Resources/markdown-viewer/", "/cmux-tui/spec/", "/clients/ts/"],
        ["/Packages/macOS/CmuxNext/Sources/CmuxNextDesign/", "/Resources/ghostty/themes/", "/Resources/cmux-themes/"],
        ["/examples/looks/", "/scripts/cmux-next/build-agent-pane-web.sh", "/config/vite-plus/", "/package.json"],
        ["*.xcstrings"],
      ),
      { cwd: dir },
    );
    run("git", ["checkout", "--quiet"], { cwd: dir });
  }
  return path.join(dir, "webviews");
}
/** The webviews/ rendered: --at's tree, else this checkout's. */
const root = args.at ? treeAt(args.at) : toolRoot;
prepare(root);
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
    : run("git", ["diff", "--name-only", `${args.base ?? "origin/feat-cmux-next"}...HEAD`], {
        cwd: path.dirname(root),
      });
  const list = path.join(work, "changed.txt");
  fs.writeFileSync(list, changed);
  // This checkout's touched.ts, beside the rendered tree's own entries.ts: an older tree's copy walked every
  // entry's imports file by file (128 s for one change, where this one takes about 2 s).
  let touchedScript = "scripts/gallery/touched.ts";
  if (root !== toolRoot) {
    touchedScript = "scripts/gallery/.proof-clip-touched.ts";
    fs.copyFileSync(path.join(toolRoot, "scripts/gallery/touched.ts"), path.join(root, touchedScript));
  }
  const touched = JSON.parse(run("bun", [touchedScript, "--changed", list], { cwd: root }));
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

// ------------------------------------------------------------------------------------------------ serve
// No build: the gallery's dev server, compiled with Oxc and kept warm between clips (proof-clip-server.mjs). The
// first clip in a checkout starts it (about 10 s to a cold stage); the next ones, after edits too, reuse it.
t0 = performance.now();
const KEEP = args.keep !== "0";
const started_servers = [];
function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
async function ensureServer(projectRoot) {
  // Keyed by checkout: a checkout whose node_modules is linked to this one's shares the folder.
  const key = createHash("sha1").update(projectRoot).digest("hex").slice(0, 12);
  const state = path.join(projectRoot, `node_modules/.cache/proof-clip/server-${key}.json`);
  const read = () => {
    try {
      return JSON.parse(fs.readFileSync(state, "utf8"));
    } catch {
      return null;
    }
  };
  const have = read();
  if (have && have.root === projectRoot && have.compiler === args.compiler && alive(have.pid)) {
    const ok = await fetch(`${have.url}/frame.html`).then(
      (r) => r.ok,
      () => false,
    );
    if (ok) return { url: have.url, reused: true };
  }
  prepare(projectRoot);
  fs.rmSync(state, { force: true });
  fs.mkdirSync(path.dirname(state), { recursive: true });
  const log = state.replace(/\.json$/, ".log");
  const logFd = fs.openSync(log, "w");
  const child = spawn(
    "node",
    [
      path.join(toolRoot, "scripts/gallery/proof-clip-server.mjs"),
      "--root",
      projectRoot,
      "--state",
      state,
      "--idle",
      args.idle,
      "--compiler",
      args.compiler,
    ],
    // Its own log: a server that outlives this run must not hold this run's stderr (a pipe reader would wait on it).
    { cwd: projectRoot, detached: true, stdio: ["ignore", logFd, logFd] },
  );
  child.unref();
  started_servers.push(child.pid);
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const now = read();
    if (now?.pid === child.pid) return { url: now.url, reused: false };
    if (child.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`the gallery server in ${projectRoot} did not start in 60 s: ${log}`);
}
const beforeRoot = args.before ? treeAt(args.before) : null;
const [after, before] = await Promise.all([ensureServer(root), beforeRoot ? ensureServer(beforeRoot) : null]);
const baseUrl = after.url;
lap("serve", t0);

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
      // The stage's own wrappers paint the page background, the whole height or the whole width of it (a pane
      // column): they are not the component.
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) continue;
      if (r.width >= innerWidth - 1 || r.height >= innerHeight - 1) continue;
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

// One context for every stage: its HTTP cache keeps the dev server's ~1200 modules after the first page, so the
// other cells load from memory. Each page sets its own color scheme.
const sharedContext = await browser.newContext({
  viewport: { width: 1040, height: 900 },
  deviceScaleFactor: SCALE,
  reducedMotion: "no-preference",
});
async function openStage(entry, variant, scheme, url = baseUrl, hover = null) {
  const page = await sharedContext.newPage();
  // A stage that cannot load (a module the server refused) says why instead of waiting out the timeout.
  const failures = [];
  page.on("pageerror", (error) => failures.push(String(error.message).split("\n")[0]));
  page.on("response", (r) => r.status() >= 400 && failures.push(`${r.status()} ${r.url().replace(url, "")}`));
  await page.emulateMedia({ colorScheme: scheme, reducedMotion: "no-preference" });
  const context = { newCDPSession: (p) => sharedContext.newCDPSession(p), close: () => page.close() };
  // settle: a stage that never goes still (the thinking line) is ready after this, not the gallery's 4 s; the
  // capture seeks its animations itself.
  const query = new URLSearchParams({
    entry,
    colorScheme: scheme,
    width: args.width,
    frame: "component",
    settle: "300",
  });
  if (variant) query.set("variant", variant);
  await page.goto(`${url}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
  await page
    .waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""), undefined, {
      timeout: 30_000,
    })
    .catch((error) => {
      throw new Error(
        `${entry}/${variant ?? ""} (${scheme}) was not ready in 30 s: ${failures.slice(0, 4).join("; ") || error.message}`,
      );
    });
  const status = await page.evaluate(() => document.documentElement.dataset.galleryReady);
  if (status !== "1") throw new Error(`${entry}/${variant ?? ""} did not render (${scheme})`);
  if (hover) {
    const target = page.locator(hover).first();
    if (!(await target.count())) throw new Error(`${entry}/${variant ?? ""}: nothing matches --hover ${hover}`);
    await target.hover({ timeout: 10_000 });
    // The hover's own transitions run out before the first frame.
    await page.evaluate(() =>
      Promise.all(
        document
          .getAnimations()
          .filter((a) => a.effect?.getComputedTiming?.().iterations !== Infinity)
          .map((a) => a.finished.catch(() => null)),
      ),
    );
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
/** One cell: a state in one scheme, rendered at the device scale that makes it MIN_CELL wide (up to --max-scale),
 * every frame taken by CDP at that scale (Playwright's own screenshot keeps the context's scale). */
async function captureCell(state, key, scheme) {
  const { context, page } = await openStage(state.entry, state.variant, scheme, state.url, state.hover);
  try {
    const m = await page.evaluate(measureStage, args.clip ?? null);
    if (m.error) throw new Error(`${key} (${scheme}): ${m.error}`);
    const box = m.box;
    const margin = marginFor(box);
    const clip = { x: Math.max(0, Math.floor(box.x - margin)), y: Math.max(0, Math.floor(box.y - margin)) };
    clip.width = Math.min(m.viewport.width - clip.x, Math.ceil(box.width + 2 * margin));
    clip.height = Math.min(m.viewport.height - clip.y, Math.ceil(box.height + 2 * margin));
    // A small element is magnified by rendering it at a higher device scale (crisp text and edges), never by
    // scaling pixels up.
    const scale = Math.min(MAX_SCALE, Math.max(SCALE, Math.floor(MIN_CELL / clip.width)));
    const cdp = await context.newCDPSession(page);
    // Always: a raw CDP capture does not see the context's own deviceScaleFactor and would come back at 1x.
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: m.viewport.width,
      height: m.viewport.height,
      deviceScaleFactor: scale,
      mobile: false,
    });
    const shot = async () =>
      Buffer.from(
        (
          await cdp.send("Page.captureScreenshot", {
            format: "png",
            clip: { ...clip, scale: 1 },
            optimizeForSpeed: true,
          })
        ).data,
        "base64",
      );
    const dir = path.join(work, "cells", key.replace(/[^\w.-]+/g, "_"), scheme);
    fs.mkdirSync(dir, { recursive: true });
    const frameFile = (i) => path.join(dir, `${String(i).padStart(4, "0")}.png`);
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
      const writes = [];
      for (let i = 0; i < frames; i++) {
        const t = (i * periodMs) / frames;
        await page.evaluate(
          ([t, origin]) =>
            document.getAnimations().forEach((a, k) => {
              a.currentTime = (origin[k] ?? 0) + t;
            }),
          [t, origin],
        );
        writes.push(fs.promises.writeFile(frameFile(i), await shot()));
      }
      await Promise.all(writes);
    } else {
      // No Web Animation: a still, unless the picture moves by script; then it is filmed in real time.
      const first = await shot();
      fs.writeFileSync(frameFile(0), first);
      const shots = [];
      let t = performance.now();
      let filmMs = 400;
      while (performance.now() - t < filmMs) {
        shots.push(await shot());
        if (filmMs < 1500 && !shots.at(-1).equals(first)) filmMs = 1500;
      }
      if (filmMs === 1500) {
        mode = "filmed";
        periodMs = Math.round(performance.now() - t);
        shots.forEach((s, i) => fs.writeFileSync(frameFile(i + 1), s));
        frames = shots.length + 1;
      }
    }
    return { dir, frames, periodMs, mode, clip, element: box, scale };
  } finally {
    await context.close();
  }
}

// Every cell at once: each is its own page on the warm server.
const jobs = [];
for (const state of rowsWanted) {
  const key = [state.side, `${state.entry}/${state.variant ?? ""}`, state.hover ? "hover" : null]
    .filter(Boolean)
    .join(" · ");
  cells.set(key, {});
  for (const scheme of SCHEMES) jobs.push(captureCell(state, key, scheme).then((c) => (cells.get(key)[scheme] = c)));
}
await Promise.all(jobs);
lap("capture", t0);

// ------------------------------------------------------------------------------------------- compose
t0 = performance.now();
const allCells = [...cells.values()].flatMap((s) => Object.values(s));
const cellW = Math.max(...allCells.map((c) => c.clip.width * c.scale));
const cellH = Math.max(...allCells.map((c) => c.clip.height * c.scale));
const even = (n) => (Math.ceil(n) + 1) & ~1;
const PW = even(cellW);
const PH = even(cellH);
// Labels scale with the cells, so a wide clip's title is not a speck once GitHub fits it to the page.
const LABEL_H = Math.max(36, Math.round(PW / 16)) & ~1;
const GAP = Math.max(8, Math.round(PW / 80)) & ~1;
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
  await runAsync("ffmpeg", [
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
    // A still is one PNG frame; motion is a lossless segment, and the one lossy step is the final encode, from these.
    ...(file.endsWith(".png")
      ? ["-frames:v", "1"]
      : ["-t", seconds.toFixed(3), "-r", String(FPS), "-c:v", "libx264rgb", "-crf", "0", "-preset", "ultrafast"]),
    file,
  ]);
}

// Nothing moves: the proof is one picture (a video of a still is seconds of encoding and a worse image).
const clipFile = path.join(out, animated ? "proof.mp4" : "proof.png");
const gifFile = animated ? path.join(out, "proof.gif") : null;
const parts = [path.join(work, "fast.mkv")];
if (slowSeconds > 0.2) parts.push(path.join(work, "slow.mkv"));
if (!animated) await segment(1, 0.1, clipFile, "still");
else
  await Promise.all([
    segment(1, fastSeconds, parts[0], "fast"),
    parts[1] ? segment(SLOW, slowSeconds, parts[1], "slow") : null,
  ]);
const list = path.join(work, "parts.txt");
fs.writeFileSync(list, parts.map((p) => `file '${p}'`).join("\n"));
const concat = ["-nostdin", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list];
await Promise.all(
  !animated
    ? []
    : [
        // The mp4 for players: near-lossless (crf 12, tuned for flat UI), 4:2:0 at two or more device pixels per CSS pixel.
        runAsync("ffmpeg", [
          ...concat,
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          "-crf",
          "12",
          "-tune",
          "animation",
          "-preset",
          "veryfast",
          "-movflags",
          "+faststart",
          clipFile,
        ]),
        // The gif a PR body shows inline: one palette from every frame, no dithering, so UI colors stay flat and exact.
        runAsync("ffmpeg", [
          ...concat,
          "-filter_complex",
          "fps=25,split[a][b];[a]palettegen=stats_mode=full:max_colors=256[p];[b][p]paletteuse=dither=none",
          gifFile,
        ]),
        runAsync("ffmpeg", [...concat, "-frames:v", "1", path.join(out, "proof.png")]),
      ],
);
lap("compose", t0);

await browser.close();
// --keep 0: stop the servers this run started (by default they stay warm for the next clip, --idle minutes).
if (!KEEP) for (const pid of started_servers) alive(pid) && process.kill(pid, "SIGTERM");

// ------------------------------------------------------------------------------------------- sidecar
const duration = animated
  ? Number(run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", clipFile]).trim())
  : 0;
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
  gif: gifFile,
  gif_bytes: gifFile ? fs.statSync(gifFile).size : null,
  bytes: fs.statSync(clipFile).size,
  max_scale: Math.max(...allCells.map((c) => c.scale)),
  compiler: args.compiler,
  server_reused: Boolean(after.reused && (!before || before.reused)),
  wall_seconds: Math.round((performance.now() - started) / 100) / 10,
  budget_s: Number(args.budget),
  phases: timings,
};
sidecar.over_budget = sidecar.wall_seconds > sidecar.budget_s;
if (sidecar.over_budget) {
  const slowest = Object.entries(timings).sort((a, b) => b[1] - a[1])[0];
  console.error(
    `proof-clip: ${sidecar.wall_seconds} s, over its ${sidecar.budget_s} s budget; slowest phase ${slowest[0]} (${slowest[1]} s)`,
  );
}
fs.writeFileSync(`${clipFile}.media.json`, `${JSON.stringify(sidecar, null, 2)}\n`);
fs.rmSync(work, { recursive: true, force: true });
console.log(JSON.stringify(sidecar));
