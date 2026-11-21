// Try a gallery variant fast: a screenshot and a short video of one entry's variants (or an
// experiment's arms) straight off the live gallery dev server, no build. The loop for a UI look:
// edit, save, run this (seconds), look at the PNG and WebM.
//
//   bun run gallery:dev &                       # once; hot reloads on save (port 4210)
//   node scripts/gallery/try-variant.mjs ENTRY [VARIANT|exp:ARM ...] [--out DIR] [--width 900]
//        [--height 720] [--scheme light|dark] [--scroll "dy,dy,..."] [--keys "Alt+ArrowUp,..."]
//        [--click SELECTOR] [--base http://127.0.0.1:4210/gallery/]
//
// VARIANT is one of the entry's variants (default: every one). `exp:ARM` picks an arm of the entry's
// experiment on its first variant. After the variant's play, the video scrolls the transcript by each
// --scroll step (px, negative is up; default a sweep up then back down), presses each --keys key and
// clicks --click, a beat apart. Writes DIR/<variant>.png (after the play) and DIR/<variant>.webm, and
// prints one JSON line per capture with its time.
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  if (at < 0) return fallback;
  const value = args[at + 1];
  args.splice(at, 2);
  return value;
};
const out = path.resolve(flag("out", "try-variant-out"));
const width = Number(flag("width", "900"));
const height = Number(flag("height", "720"));
const scheme = flag("scheme", "dark");
const base = flag("base", "http://127.0.0.1:4210/gallery/");
const scroll = flag("scroll", "-150,-150,-150,-150,-150,-150,-300,-300,300,300,300,300")
  .split(",")
  .filter(Boolean)
  .map(Number);
const keys = flag("keys", "").split(",").filter(Boolean);
const click = flag("click", "");
const [entry, ...picked] = args;
if (!entry) {
  console.error("usage: try-variant.mjs ENTRY [VARIANT|exp:ARM ...] (see the header)");
  process.exit(2);
}
fs.mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
const variants = picked.length ? picked : [""];
for (const pick of variants) {
  const started = performance.now();
  const query = new URLSearchParams({ entry, colorScheme: scheme });
  let name = pick || "default";
  if (pick.startsWith("exp:")) {
    query.set("arm", pick.slice(4));
    name = `arm-${pick.slice(4)}`;
  } else if (pick) query.set("variant", pick);
  const context = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: 2,
    colorScheme: scheme,
    recordVideo: { dir: out, size: { width, height } },
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  const url = `${base}frame.html?${query}`;
  // An arm needs the experiment's id too: read it from the entry once the frame knows it.
  await page.goto(url);
  if (pick.startsWith("exp:")) {
    const id = await page.evaluate(() => globalThis.cmuxGalleryExperimentId).catch(() => undefined);
    if (id) await page.goto(`${url}&exp=${encodeURIComponent(id)}`);
  }
  // The frame marks the end of a variant's play (gallery/frame/playRunner.ts) on the root.
  await page
    .waitForFunction(
      () => document.documentElement.dataset.playDone !== undefined || document.querySelector(".acpmux-scroll"),
      null,
      { timeout: 30_000 },
    )
    .catch(() => {});
  await page.waitForTimeout(1_200);
  await page.screenshot({ path: path.join(out, `${name}.png`) });
  const scroller = ".acpmux-scroll";
  for (const dy of scroll) {
    await page.evaluate(([sel, by]) => document.querySelector(sel)?.scrollBy({ top: by }), [scroller, dy]);
    await page.waitForTimeout(160);
  }
  for (const key of keys) {
    await page.keyboard.press(key);
    await page.waitForTimeout(700);
  }
  if (click) {
    await page.click(click, { timeout: 3_000 }).catch((error) => errors.push(`click: ${error.message}`));
    await page.waitForTimeout(900);
  }
  await page.waitForTimeout(400);
  const video = page.video();
  await context.close();
  const file = path.join(out, `${name}.webm`);
  if (video) fs.renameSync(await video.path(), file);
  console.log(
    JSON.stringify({
      entry,
      variant: name,
      png: path.join(out, `${name}.png`),
      webm: file,
      ms: Math.round(performance.now() - started),
      errors,
    }),
  );
}
await browser.close();
