// Every gallery state at a pane width: text cut off with no ellipsis, and content wider than the pane.
import fs from "node:fs"; import path from "node:path";
import { chromium } from "playwright"; import { preview } from "vite";
const root = process.env.WEBVIEWS ?? "webviews";
const [, , widthsArg = "narrow,normal", outFile = "/tmp/ctscan/out.jsonl", par = "8", only = ""] = process.argv;
const entries = JSON.parse(fs.readFileSync(process.env.ENTRIES ?? "/tmp/dgscan/entries.json", "utf8"));
const jobs = [];
for (const width of widthsArg.split(",")) for (const e of entries) {
  if (only && !only.split(",").includes(e.id)) continue;
  for (const v of e.variants.length ? e.variants : [""]) jobs.push([width, e.id, v]);
}
const server = await preview({ root, configFile: path.join(root, "vite.config.gallery.ts"), preview: { host: "127.0.0.1", port: 0 } });
const base = `http://127.0.0.1:${server.httpServer.address().port}`;
const browser = await chromium.launch({ channel: "chrome" });
const out = fs.createWriteStream(outFile);
const audit = () => {
  const name = (el) => el.tagName.toLowerCase() + (el.classList.length ? "." + [...el.classList].slice(0, 3).join(".") : "");
  const set = (v) => !!v && v !== "none";
  const cuts = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const seen = new Set();
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const text = n.textContent.trim(); if (text.length < 2) continue;
    const host = n.parentElement; if (!host || seen.has(host)) continue;
    const hs = getComputedStyle(host);
    if (hs.visibility === "hidden" || parseFloat(hs.opacity) === 0) continue;
    const range = document.createRange(); range.selectNodeContents(n);
    const rects = [...range.getClientRects()].filter((r) => r.width > 0 && r.height > 0); if (!rects.length) continue;
    const right = Math.max(...rects.map((r) => r.right)), left = Math.min(...rects.map((r) => r.left));
    let ellipsis = false, faded = false;
    for (let a = host; a && a !== document.documentElement; a = a.parentElement) {
      const s = getComputedStyle(a);
      if (s.textOverflow === "ellipsis") ellipsis = true;
      if (set(s.maskImage || s.getPropertyValue("-webkit-mask-image"))) faded = true;
      if (s.opacity === "0") break;
      const ox = s.overflowX;
      if (ox === "auto" || ox === "scroll") break; // a scroller: cut at its edge on purpose
      if (ox !== "hidden" && ox !== "clip" && s.contain.indexOf("paint") < 0) continue;
      const b = a.getBoundingClientRect();
      const clipR = b.right - parseFloat(s.borderRightWidth); const clipL = b.left + parseFloat(s.borderLeftWidth);
      if (clipR - clipL <= 2) break; // visually hidden (sr-only)
      if (left < clipR - 2 && right > clipR + 2) {
        seen.add(host);
        if (!ellipsis && !faded) cuts.push({ axis: "x", text: name(host), clip: a === host ? "self" : name(a), by: Math.round(right - clipR), of: Math.round(right - left), sample: text.slice(0, 40) });
      }
      break;
    }
  }
  // Vertical: a line box cut by an overflow-y hidden/clip ancestor (no line-clamp, not a scroller).
  const w2 = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); const seenY = new Set();
  for (let n = w2.nextNode(); n; n = w2.nextNode()) {
    const text = n.textContent.trim(); if (text.length < 2) continue;
    const host = n.parentElement; if (!host || seenY.has(host)) continue;
    const hs = getComputedStyle(host); if (hs.visibility === "hidden" || parseFloat(hs.opacity) === 0) continue;
    const range = document.createRange(); range.selectNodeContents(n);
    const rects = [...range.getClientRects()].filter((r) => r.width > 0 && r.height > 0); if (!rects.length) continue;
    let clamp = false, faded = false;
    for (let a = host; a && a !== document.documentElement; a = a.parentElement) {
      const s = getComputedStyle(a);
      if (s.webkitLineClamp && s.webkitLineClamp !== "none") clamp = true;
      if (set(s.maskImage || s.getPropertyValue("-webkit-mask-image"))) faded = true;
      const oy = s.overflowY; if (oy === "auto" || oy === "scroll") break;
      if (oy !== "hidden" && oy !== "clip" && s.contain.indexOf("paint") < 0) continue;
      const b = a.getBoundingClientRect(); if (b.height <= 2 || b.width <= 2) break;
      const clipB = b.bottom - parseFloat(s.borderBottomWidth), clipT = b.top + parseFloat(s.borderTopWidth);
      // a line partly visible: top inside, bottom past the edge by 2px+ (a line wholly outside is a hidden part, not a cut)
      const cut = rects.find((r) => (r.top < clipB - 2 && r.bottom > clipB + 2) || (r.bottom > clipT + 2 && r.top < clipT - 2));
      if (cut) { seenY.add(host); if (!clamp && !faded) cuts.push({ axis: "y", text: name(host), clip: a === host ? "self" : name(a), by: Math.round(cut.bottom > clipB ? cut.bottom - clipB : clipT - cut.top), of: Math.round(cut.height), sample: text.slice(0, 40) }); }
      break;
    }
  }
  const se = document.scrollingElement;
  return { cuts, pageOverflow: Math.max(0, se.scrollWidth - innerWidth) };
};
let i = 0;
async function worker() {
  let ctx = await browser.newContext({ viewport: { width: 1100, height: 760 }, colorScheme: "dark" });
  let page = await ctx.newPage();
  while (i < jobs.length) {
    const [width, entry, variant] = jobs[i++];
    const q = new URLSearchParams({ entry, colorScheme: "dark", width, frame: "component" });
    if (variant) q.set("variant", variant);
    try {
      await page.goto(`${base}/frame.html?${q}`, { waitUntil: "domcontentloaded", timeout: 30000 });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 20000 });
      await page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300))))));
      const r = await page.evaluate(audit);
      out.write(JSON.stringify({ width, entry, variant, ...r }) + "\n");
    } catch (e) {
      out.write(JSON.stringify({ width, entry, variant, error: String(e).split("\n")[0].slice(0, 160) }) + "\n");
      await ctx.close().catch(() => {}); ctx = await browser.newContext({ viewport: { width: 1100, height: 760 }, colorScheme: "dark" }); page = await ctx.newPage();
    }
  }
  await ctx.close();
}
const t0 = Date.now();
await Promise.all(Array.from({ length: +par }, worker));
out.end(); await browser.close(); server.httpServer.close();
console.log(`done ${jobs.length} jobs in ${Math.round((Date.now() - t0) / 1000)} s`);
process.exit(0);
