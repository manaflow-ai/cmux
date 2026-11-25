// Usage: node capture.mjs ROUND [variant,...]
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
const require = createRequire(path.resolve(process.env.WEBVIEWS ?? "webviews", "package.json"));
const { chromium } = require("playwright-core");
const round = process.argv[2];
const only = process.argv[3]?.split(",");
const out = path.resolve(process.env.OUT ?? "verify/customize-paradigm", `round-${round}`);
fs.mkdirSync(out, { recursive: true });
const base = "http://127.0.0.1:4377/gallery";
const browser = await chromium.launch({ executablePath: "/usr/bin/google-chrome", args: ["--no-sandbox"] });
const report = {};
const W = { tiny: 480, narrow: 720, normal: 980, wide: 1280 };
async function open(variant, width, scheme, viewport = { width: W[width], height: 800 }) {
  const context = await browser.newContext({ viewport, deviceScaleFactor: 1, colorScheme: scheme });
  const page = await context.newPage();
  const q = new URLSearchParams({ entry: "pages.customize-studio", variant, colorScheme: scheme, width, frame: "component" });
  for (let attempt = 0; ; attempt++) {
    try {
      await page.goto(`${base}/frame.html?${q}`, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 20000 });
      break;
    } catch (error) { if (attempt === 3) throw error; }
  }
  await page.waitForSelector(".customize-studio");
  await page.waitForTimeout(250);
  return { context, page };
}
// Static audit: clipped text, things outside the studio, uneven sibling tops.
const audit = () => {
  const root = document.querySelector(".customize-studio");
  const rr = root.getBoundingClientRect();
  const issues = [];
  for (const el of root.querySelectorAll("*")) {
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) continue;
    const name = el.className && typeof el.className === "string" ? el.className.split(" ")[0] : el.tagName;
    if (r.right > rr.right + 1 || r.left < rr.left - 1) issues.push(`outside-root ${name} ${Math.round(r.right - rr.right)}px`);
    const cs = getComputedStyle(el);
    if (el.children.length === 0 && el.textContent.trim() && (el.scrollWidth > el.clientWidth + 1) && cs.overflow !== "visible")
      issues.push(`clipped-text ${name} "${el.textContent.trim().slice(0, 30)}"`);
    if (el.children.length === 0 && el.textContent.trim() && r.height > parseFloat(cs.lineHeight || 16) * 2.6 && !name.startsWith("studio-muted"))
      issues.push(`3+line-wrap ${name} "${el.textContent.trim().slice(0, 30)}"`);
    if (cs.fontSize && parseFloat(cs.fontSize) > 0 && parseFloat(cs.fontSize) < 10 && el.children.length === 0 && el.textContent.trim())
      issues.push(`tiny-text ${name} ${cs.fontSize}`);
  }
  for (const b of root.querySelectorAll("button")) {
    const r = b.getBoundingClientRect();
    if (r.height < 20 || r.width < 20) issues.push(`small-target ${b.className.split(" ")[0]} ${Math.round(r.width)}x${Math.round(r.height)}`);
  }
  return { h: Math.round(rr.height), w: Math.round(rr.width), issues: [...new Set(issues)] };
};
const startSampler = () => {
  const root = document.querySelector(".customize-studio");
  const s = (window.__s = { heights: new Set(), tops: {}, on: true, frames: 0, long: 0, last: performance.now() });
  const tick = () => {
    if (!s.on) return;
    const now = performance.now();
    if (now - s.last > 34) s.long++;
    s.last = now; s.frames++;
    // A full-page screenshot shrinks the viewport to 1x1 for a frame: that is the camera, not the page.
    if (innerWidth < 100) return requestAnimationFrame(tick);
    s.heights.add(Math.round(root.getBoundingClientRect().height));
    for (const el of root.querySelectorAll("[data-customization],[data-setup],.mini-cmux-large")) {
      if (getComputedStyle(el.closest(".studio-detail,.studio-manager-preview") ?? el).position === "sticky" || getComputedStyle(el).position === "sticky") continue;
      const k = (el.dataset.customization || el.dataset.setup || "live") + ":" + el.className.split(" ")[0];
      const r = el.getBoundingClientRect();
      (s.tops[k] ??= new Set()).add(`${Math.round(r.top + window.scrollY)},${Math.round(r.left)},${Math.round(r.height)}`);
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
};
const stopSampler = () => {
  const s = window.__s; s.on = false;
  const moved = Object.entries(s.tops).filter(([, v]) => v.size > 1).map(([k, v]) => `${k} x${v.size}`);
  return { heights: [...s.heights], moved, frames: s.frames, longFrames: s.long };
};
const variants = await (async () => {
  const { context, page } = await open("manager-teammate", "normal", "dark");
  await context.close();
  return only ?? JSON.parse(fs.readFileSync(path.join(out, "..", "variants.json"), "utf8"));
})();
for (const variant of variants) {
  const rep = (report[variant] = {});
  for (const [width, scheme] of [["normal", "dark"], ["narrow", "dark"], ["wide", "dark"], ["tiny", "dark"], ["normal", "light"]]) {
    const { context, page } = await open(variant, width, scheme);
    rep[`${width}-${scheme}`] = await page.evaluate(audit);
    await page.screenshot({ path: path.join(out, `${variant}--${width}-${scheme}.png`), fullPage: true });
    await context.close();
  }
  // Flick: rapid toggle. Every switch, 6 passes, no wait; a screenshot mid-burst.
  {
    const { context, page } = await open(variant, "normal", "dark");
    await page.evaluate(startSampler);
    const switches = page.locator(".customize-studio [role=switch]");
    const n = await switches.count();
    for (let pass = 0; pass < 6; pass++) {
      for (let i = 0; i < Math.min(n, await switches.count()); i++) await switches.nth(i).click({ noWaitAfter: true, delay: 0, force: true, timeout: 800 }).catch(() => {});
      if (pass === 2) await page.screenshot({ path: path.join(out, `${variant}--flick-toggle-mid.png`), fullPage: true });
    }
    rep.flickToggle = await page.evaluate(stopSampler);
    await page.waitForTimeout(400);
    await page.screenshot({ path: path.join(out, `${variant}--flick-toggle-end.png`), fullPage: true });
    // Rapid setup switching.
    await page.evaluate(startSampler);
    const setups = page.locator(".customize-studio [data-setup]:is(button), .customize-studio [data-setup] button, .customize-studio [data-action]");
    const m = await setups.count();
    for (let pass = 0; pass < 5; pass++) for (let i = 0; i < m; i++) await setups.nth(i).click({ force: true, noWaitAfter: true, timeout: 800 }).catch(() => {});
    rep.flickSetup = await page.evaluate(stopSampler);
    await page.screenshot({ path: path.join(out, `${variant}--flick-setup-end.png`), fullPage: true });
    await context.close();
  }
  // Flick: rapid hover across rows and cards, 2 ms apart.
  {
    const { context, page } = await open(variant, "normal", "dark");
    const boxes = await page.locator(".customize-studio [data-customization]").evaluateAll((els) => els.map((el) => { const r = el.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }));
    await page.evaluate(startSampler);
    for (let pass = 0; pass < 8; pass++) {
      for (const [x, y] of pass % 2 ? [...boxes].reverse() : boxes) await page.mouse.move(x, y, { steps: 2 });
      if (pass === 3) await page.screenshot({ path: path.join(out, `${variant}--flick-hover-mid.png`), fullPage: true });
      await page.mouse.move(5, 5);
    }
    rep.flickHover = await page.evaluate(stopSampler);
    await context.close();
  }
  // Flick: rapid scroll in a short window (the Settings pane at 520 tall), wheel bursts both ways.
  {
    const { context, page } = await open(variant, "narrow", "dark", { width: 720, height: 520 });
    await page.mouse.move(400, 300);
    await page.evaluate(startSampler);
    for (let i = 0; i < 30; i++) await page.mouse.wheel(0, i % 10 < 6 ? 400 : -700);
    await page.screenshot({ path: path.join(out, `${variant}--flick-scroll-mid.png`) });
    for (let i = 0; i < 30; i++) await page.mouse.wheel(0, -600);
    rep.flickScroll = await page.evaluate(stopSampler);
    rep.flickScroll.scrollH = await page.evaluate(() => [document.scrollingElement.scrollHeight, innerHeight, document.scrollingElement.scrollWidth, innerWidth]);
    await context.close();
  }
  console.log(variant, JSON.stringify(rep));
}
fs.writeFileSync(path.join(out, "report.json"), JSON.stringify(report, null, 1));
await browser.close();
