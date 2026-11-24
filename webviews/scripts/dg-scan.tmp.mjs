// Scan every gallery entry/variant for nested backdrop roots under a backdrop-filter surface.
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { preview } from "vite";
const root = "/home/cmux/.wt/checkouts/cmux/lane--double-glass-scan/webviews";
const [, , mode = "first", outFile = "/tmp/dgscan/out.jsonl", par = "8"] = process.argv;
const entries = JSON.parse(fs.readFileSync("/tmp/dgscan/entries.json", "utf8"));
const jobs = [];
for (const e of entries) { const vs = e.variants.length ? e.variants : [""]; for (const v of mode === "all" ? vs : vs.slice(0, 1)) jobs.push([e.id, v]); }
const server = await preview({ root, configFile: path.join(root, "vite.config.gallery.ts"), preview: { host: "127.0.0.1", port: 0 } });
const base = `http://127.0.0.1:${server.httpServer.address().port}`;
const browser = await chromium.launch({ channel: "chrome" });
const out = fs.createWriteStream(outFile);
const audit = () => {
  const set = (v) => !!v && v !== "none";
  const rootWhy = (s) => {
    const r = [];
    if (set(s.backdropFilter || s.getPropertyValue("-webkit-backdrop-filter"))) r.push("backdrop-filter");
    if (set(s.filter)) r.push("filter");
    if (set(s.maskImage || s.getPropertyValue("-webkit-mask-image"))) r.push("mask");
    if (set(s.clipPath)) r.push("clip-path");
    const o = parseFloat(s.opacity); if (Number.isFinite(o) && o < 1) r.push("opacity");
    if (s.mixBlendMode && s.mixBlendMode !== "normal") r.push("blend");
    return r;
  };
  const name = (el) => el.tagName.toLowerCase() + (el.classList.length ? "." + [...el.classList].slice(0, 3).join(".") : "");
  const visible = (el, s) => { const b = el.getBoundingClientRect(); return b.width > 2 && b.height > 2 && s.visibility !== "hidden" && s.display !== "none"; };
  const glass = [], hits = [];
  for (const el of document.querySelectorAll("body *")) {
    const s = getComputedStyle(el);
    if (!set(s.backdropFilter || s.getPropertyValue("-webkit-backdrop-filter")) || !visible(el, s)) continue;
    glass.push(el);
    for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
      const why = rootWhy(getComputedStyle(a));
      if (why.length) { const b = el.getBoundingClientRect(); hits.push({ inner: name(el), innerBlur: s.backdropFilter, outer: name(a), why: why.join("+"), area: Math.round(b.width * b.height), host: el.closest("[data-host-glass]") ? 1 : 0 }); break; }
    }
  }
  return { glass: glass.length, hits };
};
let i = 0;
async function worker() {
  const ctx = await browser.newContext({ viewport: { width: 1100, height: 760 }, colorScheme: "dark" });
  let page = await ctx.newPage();
  while (i < jobs.length) {
    const [entry, variant] = jobs[i++];
    const q = new URLSearchParams({ entry, colorScheme: "dark", width: "normal", frame: "component" });
    if (variant) q.set("variant", variant);
    try {
      await page.goto(`${base}/frame.html?${q}`, { waitUntil: "domcontentloaded", timeout: 30000 });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 20000 });
      await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300)))));
      const r = await page.evaluate(audit);
      out.write(JSON.stringify({ entry, variant, ...r }) + "\n");
    } catch (e) { if (page.isClosed() || /crash/i.test(String(e))) { await page.close().catch(() => {}); page = await ctx.newPage(); } out.write(JSON.stringify({ entry, variant, error: String(e).slice(0, 160) }) + "\n"); }
  }
  await ctx.close();
}
const t0 = Date.now();
await Promise.all(Array.from({ length: +par }, worker));
out.end(); await browser.close(); server.httpServer.close();
console.log(`done ${jobs.length} jobs in ${Math.round((Date.now() - t0) / 1000)} s`);
process.exit(0);
