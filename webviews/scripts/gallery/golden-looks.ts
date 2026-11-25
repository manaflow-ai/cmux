// l10n-allow-file: capture tool, no shipped UI.
// The golden screen per look (gallery entry looks.golden, src/gallery/golden/looks.json), captured in the
// mock app's whole window (sidebar, tab strip, the real agent pane): one PNG per look and scheme, and
// sheet.png with every look side by side, light and dark. A look PR posts its golden before and after
// from the base and its head.
//
//   bun run golden:looks [--looks cmux,claude] [--schemes light,dark] [--out DIR] [--window 1280x2000]
//     [--setup DIR ...] [--native DIR] [--every] [--preview] [--video DIR]
//
// --video also records DIR/looks.webm: every look and scheme in turn, its name over the window, the chat
// scrolled from the first prompt to the composer (a demo of the looks to post or send).
// --setup adds a look from any setup folder (a look's own repo, ~/src/my-look), beside the built-in ones.
// --preview (with --setup) also writes each setup folder's own stills, DIR/preview/golden-light.png and
// DIR/preview/golden-dark.png (previewPath), the files the Settings looks gallery shows; it captures only
// the setup looks unless --looks names others.
// --every adds every other look the checkout carries (each shipped theme file, examples/ setup folder and
// theme file: goldenLooks.ts discoverLooks), as the golden contrast test draws them.
// --native adds the native sidebar and tab bar captures (Swift AAGoldenLookGalleryTests, its
// golden-look-gallery/<look>-<scheme>.png) as a column beside each look's window.
// On a lane VM: `cmux-ci test --artifact /tmp/golden -- bun run golden:looks --out "$FAST_CHECKS_OUT/golden"`.
import { copyFileSync, mkdirSync, readdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { chromium, type Page } from "playwright";

const { values } = parseArgs({
  options: {
    looks: { type: "string" },
    schemes: { type: "string", default: "light,dark" },
    out: {
      type: "string",
      default: process.env.FAST_CHECKS_OUT ? path.join(process.env.FAST_CHECKS_OUT, "golden") : "/tmp/golden-looks",
    },
    window: { type: "string", default: "1280x2000" },
    setup: { type: "string", multiple: true, default: [] },
    native: { type: "string" },
    every: { type: "boolean", default: false },
    preview: { type: "boolean", default: false },
    scale: { type: "string", default: "1" },
    video: { type: "string" },
  },
});
const webviews = path.resolve(import.meta.dir, "../..");
const out = path.resolve(values.out!);
mkdirSync(out, { recursive: true });
// The gallery's looks module reads outside setups from this (dev-server/goldenLooks.ts).
process.env.CMUX_GOLDEN_SETUPS = values.setup!.map((dir) => path.resolve(dir)).join(",");
if (values.every) process.env.CMUX_GOLDEN_EVERY_LOOK = "1";
const { previewPath, readGoldenLooks } = await import("../../dev-server/goldenLooks");
if (values.preview && values.setup!.length === 0) {
  console.error("golden: --preview writes into a setup folder: give it --setup DIR");
  process.exit(64);
}
const setupDirs = new Set(values.setup!.map((dir) => path.resolve(dir)));
const registry = readGoldenLooks();
for (const skip of registry.skipped) console.log(`golden: skipped ${skip.id}: ${skip.reason}`);
const wanted = values.looks?.split(",").filter(Boolean);
const looks = registry.looks.filter((look) =>
  wanted ? wanted.includes(look.id) : !values.preview || (look.setupDir !== undefined && setupDirs.has(look.setupDir)),
);
const schemes = values.schemes!.split(",").filter((s): s is "light" | "dark" => s === "light" || s === "dark");
const [width, height] = values.window!.split("x").map(Number) as [number, number];
const deviceScaleFactor = Number(values.scale) || 1;
/** The tallest window the capture grows to. */
const MAX_HEIGHT = 4000;
/** The video's window height: a laptop-sized window the chat scrolls through. */
const VIDEO_HEIGHT = 820;

const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1" },
  logLevel: "error",
});
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const browser = await chromium.launch({ headless: true });

/** The pane's stage: drawn, its fonts loaded and the permission's diff painted (Pierre, in a shadow root). */
async function settled(page: Page): Promise<void> {
  await page.waitForSelector('html[data-mock-app-ready="1"]', { timeout: 120_000 });
  const frame = page.frames().find((candidate) => candidate.url().includes("frame.html"));
  if (!frame) throw new Error("golden: the mock app has no pane frame");
  await frame.waitForSelector(".cv-user__bubble", { timeout: 60_000 });
  await frame
    .waitForFunction(
      () =>
        [...document.querySelectorAll(".cv-edit-diff__body diffs-container")].some(
          (container) => (container.shadowRoot?.querySelectorAll("[data-line]").length ?? 0) > 0,
        ),
      undefined,
      { timeout: 20_000 },
    )
    .catch(() => console.log("golden: no painted diff in the permission prompt (drawn without it)"));
  for (const target of [page, frame]) await target.evaluate(() => document.fonts.ready.then(() => undefined));
  await frame.evaluate(
    () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
  );
}

const shots: { look: string; title: string; note: string; scheme: string; file: string }[] = [];
const page = await browser.newPage({ viewport: { width: width + 64, height: height + 96 }, deviceScaleFactor });

/** Loads one look in a window `tall` px high; answers how much taller the chat is than its pane. */
async function load(
  look: (typeof looks)[number],
  scheme: "light" | "dark",
  tall: number,
  on: Page = page,
): Promise<number> {
  const query = new URLSearchParams({
    fixture: `looks.golden/${look.id}`,
    colorScheme: scheme,
    window: `${width}x${tall}`,
    zoom: "1",
  });
  // The look's density (its theme file's appearance.density): the window's metrics and the pane's.
  const density = look.schemes[scheme].density;
  if (density) query.set("density", density);
  await on.setViewportSize({ width: width + 64, height: tall + 96 });
  // The dev server's first loads may reload the page as its dependency optimizer settles: load again.
  for (let attempt = 1; ; attempt += 1) {
    try {
      await on.goto(`http://127.0.0.1:${port}/gallery/mock-app.html?${query}`);
      await settled(on);
      break;
    } catch (error) {
      if (attempt >= 4) throw error;
      console.log(`golden: ${look.id} ${scheme} loads again (${String(error).split("\n")[0]})`);
    }
  }
  const frame = on.frames().find((candidate) => candidate.url().includes("frame.html"))!;
  return frame.evaluate(() => {
    const scroll = document.querySelector(".acpmux-scroll");
    return scroll ? Math.max(0, scroll.scrollHeight - scroll.clientHeight) : 0;
  });
}

for (const look of looks)
  for (const scheme of schemes) {
    // The window grows until the whole chat shows, first prompt to composer: nothing is cut.
    let tall = height;
    for (let pass = 0; pass < 4; pass += 1) {
      const more = await load(look, scheme, tall);
      if (more <= 2 || tall >= MAX_HEIGHT) break;
      tall = Math.min(MAX_HEIGHT, tall + more + 8);
    }
    const file = path.join(out, `${look.id}-${scheme}.png`);
    await page.locator(".app-window").first().screenshot({ path: file, animations: "disabled" });
    shots.push({ look: look.id, title: look.title, note: look.note, scheme, file });
    console.log(`golden: ${file} (${width}x${tall})`);
    if (values.preview && look.setupDir && setupDirs.has(look.setupDir)) {
      const preview = previewPath(look.setupDir, scheme);
      mkdirSync(path.dirname(preview), { recursive: true });
      copyFileSync(file, preview);
      console.log(`golden: preview ${preview}`);
    }
  }

// The sheet: one row per look, its schemes side by side (and the native captures when given).
const nativeDir = values.native ? path.resolve(values.native) : undefined;
const native = nativeDir && existsSync(nativeDir) ? new Set(readdirSync(nativeDir)) : new Set<string>();
const dataUrl = (file: string) => `data:image/png;base64,${readFileSync(file).toString("base64")}`;
const escape = (text: string) => text.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);
const cell = (title: string, src: string | undefined, kind = "window") =>
  `<figure><figcaption>${escape(title)}</figcaption>${src ? `<img class=${kind} src="${src}">` : "<div class=none>not captured</div>"}</figure>`;
const rows = looks.map((look) => {
  const cells = schemes.flatMap((scheme) => {
    const shot = shots.find((candidate) => candidate.look === look.id && candidate.scheme === scheme);
    const nativeName = `${look.id}-${scheme}.png`;
    return [
      cell(scheme, shot && dataUrl(shot.file)),
      ...(nativeDir
        ? [
            cell(
              `${scheme}, native sidebar and tabs`,
              native.has(nativeName) ? dataUrl(path.join(nativeDir, nativeName)) : undefined,
              "native",
            ),
          ]
        : []),
    ];
  });
  return `<section><h2>${escape(look.title)}</h2><p>${escape(look.note)}</p><div class=row>${cells.join("")}</div></section>`;
});
const columns = schemes.length * (nativeDir ? 2 : 1);
const sheet = `<!doctype html><meta charset=utf-8><style>
  body { margin: 0; padding: 24px; background: #8a8a8a; font: 14px -apple-system, system-ui, sans-serif; color: #111; }
  section { margin-bottom: 28px; }
  h2 { margin: 0 0 2px; font-size: 20px; }
  p { margin: 0 0 8px; color: #222; max-width: 1200px; }
  .row { display: grid; grid-template-columns: repeat(${columns}, auto); gap: 16px; justify-content: start; align-items: start; }
  figure { margin: 0; }
  figcaption { font-size: 12px; margin-bottom: 4px; color: #1a1a1a; }
  img { display: block; width: ${Math.round(width / 2)}px; height: auto; border-radius: 10px; }
  img.native { width: auto; }
  .none { width: ${Math.round(width / 2)}px; height: 120px; display: grid; place-items: center; background: #777; border-radius: 10px; }
</style>${rows.join("")}`;
writeFileSync(path.join(out, "sheet.html"), sheet);
const sheetPage = await browser.newPage({ viewport: { width: 1200, height: 800 }, deviceScaleFactor: 1 });
await sheetPage.setContent(sheet, { waitUntil: "load" });
await sheetPage.screenshot({ path: path.join(out, "sheet.png"), fullPage: true });
console.log(`golden: ${path.join(out, "sheet.png")} (${looks.length} looks, ${schemes.join(" and ")})`);

// --video: one walkthrough, every look and scheme in turn in a window VIDEO_HEIGHT high, its name over the
// window, the chat scrolled from the first prompt down to the composer.
if (values.video) {
  const videoDir = path.resolve(values.video);
  mkdirSync(videoDir, { recursive: true });
  const size = { width: width + 64, height: VIDEO_HEIGHT + 96 };
  const context = await browser.newContext({ viewport: size, recordVideo: { dir: videoDir, size } });
  const tour = await context.newPage();
  // While a look loads, a title card with its name covers the half-drawn window; once it settles the card
  // shrinks to a tag at the top right. The name rides in window.name, which outlives the navigation.
  await tour.addInitScript(() => {
    if (window !== window.top || !window.name.startsWith("golden:")) return;
    const label = window.name.slice("golden:".length);
    document.addEventListener("DOMContentLoaded", () => {
      const tag = document.createElement("div");
      tag.id = "golden-video-tag";
      tag.textContent = label;
      tag.style.cssText =
        "position:fixed;inset:0;z-index:99999;display:grid;place-items:center;font:600 44px system-ui,sans-serif;" +
        "color:#fff;background:#111";
      document.body.append(tag);
    });
  });
  for (const look of looks)
    for (const scheme of schemes) {
      await tour.evaluate((label) => (window.name = `golden:${label}`), `${look.title}, ${scheme}`);
      await load(look, scheme, VIDEO_HEIGHT, tour);
      await tour.evaluate(() => {
        const tag = document.getElementById("golden-video-tag");
        if (!tag) return;
        tag.style.cssText =
          "position:fixed;right:32px;top:8px;z-index:99999;font:600 22px system-ui,sans-serif;color:#fff;" +
          "background:rgba(0,0,0,.72);padding:6px 14px;border-radius:8px";
      });
      const frame = tour.frames().find((candidate) => candidate.url().includes("frame.html"))!;
      await frame.evaluate(async () => {
        const scroll = document.querySelector(".acpmux-scroll");
        if (!scroll) return;
        const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
        scroll.scrollTop = 0;
        await pause(1200);
        const end = scroll.scrollHeight - scroll.clientHeight;
        const start = performance.now();
        const span = Math.min(5000, Math.max(1500, end * 4));
        await new Promise<void>((resolve) => {
          const step = (now: number) => {
            const t = Math.min(1, (now - start) / span);
            scroll.scrollTop = end * (t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2);
            if (t < 1) requestAnimationFrame(step);
            else resolve();
          };
          requestAnimationFrame(step);
        });
        await pause(1200);
      });
      console.log(`golden: video ${look.id} ${scheme}`);
    }
  const recording = tour.video();
  await context.close();
  if (recording) {
    const file = path.join(videoDir, "looks.webm");
    await recording.saveAs(file);
    await recording.delete();
    console.log(`golden: ${file} (${looks.length} looks, ${schemes.join(" and ")})`);
  }
}
await browser.close();
await vite.close();
