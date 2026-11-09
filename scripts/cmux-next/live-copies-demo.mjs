// The live-copies demo and check: three copies of the Settings page live side by side, each edited on
// its own, each hot-reloading only itself. It drives the compare page that live-copies.sh wrote.
//
//   scripts/cmux-next/live-copies.sh start 3 --from HEAD --set demo --page '/settings/?mock'
//   node scripts/cmux-next/live-copies-demo.mjs demo OUT_DIR
//
// It writes OUT_DIR/1-started.png (three identical copies), 2-edited.png (each copy its own variant),
// 3-one-more.png (copy 2 edited again; 1 and 3 unchanged) and result.json (each copy's save-to-frame
// time and whether its frame kept its page state, which a hot update does and a reload does not).
// Exits 1 when a copy did not update, reloaded, or changed with another copy's edit.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../webviews/package.json", import.meta.url));
const { chromium } = require("playwright");

const [setName, out = path.resolve("live-copies-demo")] = process.argv.slice(2);
if (!setName) throw new Error("usage: live-copies-demo.mjs SET [OUT_DIR]");
const base = process.env.CMUX_LIVE_COPIES_DIR
  || (process.platform === "darwin"
    ? path.join(os.homedir(), "Library/Caches/cmux-next/live-copies")
    : path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache"), "cmux-next/live-copies"));
const setDir = path.join(base, setName);
const data = JSON.parse(fs.readFileSync(path.join(setDir, "copies.json"), "utf8"));
fs.mkdirSync(out, { recursive: true });

const variants = [
  { label: "Variant A: warm", background: "#e8590c" },
  { label: "Variant B: green", background: "#2f9e44" },
  { label: "Variant C: cool", background: "#1971c2" },
];
const cssFile = (copy) => path.join(copy.worktree, "webviews/src/pages/settings/page.css");
const banner = (v) => `\n/* live-copies demo */\nbody::before { content: "${v.label}"; display: block; padding: 10px 16px; background: ${v.background}; color: white; font: 600 15px system-ui; }\n`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1800, height: 900 } });
await page.goto(`file://${path.join(setDir, "compare.html")}`);
const frameOf = async (copy) => {
  const handle = await page.waitForSelector(`iframe[title="Copy ${copy.index}"]`);
  return handle.contentFrame();
};
const frames = await Promise.all(data.copies.map(frameOf));
await Promise.all(frames.map((f) => f.waitForFunction(() => document.body && document.body.innerText.trim().length > 40, null, { timeout: 120_000 })));
await page.waitForTimeout(1500);
await page.screenshot({ path: path.join(out, "1-started.png") });

const before = (f) => f.evaluate(() => getComputedStyle(document.body, "::before").content);
// A mark in each frame's page: a hot update keeps it, a reload loses it.
await Promise.all(frames.map((f, i) => f.evaluate((k) => { window.__liveCopyMark = k; }, i + 1)));

const result = { set: setName, copies: [] };
const edit = async (i, v) => {
  const copy = data.copies[i];
  const t0 = Date.now();
  fs.appendFileSync(cssFile(copy), banner(v));
  await frames[i].waitForFunction((label) => getComputedStyle(document.body, "::before").content.includes(label), v.label, { timeout: 30_000 });
  return { index: copy.index, label: v.label, saveToFrameMs: Date.now() - t0, keptState: await frames[i].evaluate(() => window.__liveCopyMark ?? null) === i + 1 };
};
for (let i = 0; i < frames.length; i++) result.copies.push(await edit(i, variants[i % variants.length]));
await page.waitForTimeout(500);
await page.screenshot({ path: path.join(out, "2-edited.png") });
const edited = await Promise.all(frames.map(before));

// One more edit, to copy 2 only: the others must not change.
const again = { label: "Variant B, second try", background: "#862e9c" };
result.secondEdit = await edit(1, again);
await page.waitForTimeout(500);
await page.screenshot({ path: path.join(out, "3-one-more.png") });
const after = await Promise.all(frames.map(before));
result.othersUnchanged = after.every((c, i) => i === 1 || c === edited[i]);

await browser.close();
fs.writeFileSync(path.join(out, "result.json"), JSON.stringify(result, null, 2) + "\n");
console.log(JSON.stringify(result, null, 2));
const ok = result.copies.every((c) => c.keptState) && result.secondEdit.keptState && result.othersUnchanged;
process.exit(ok ? 0 : 1);
