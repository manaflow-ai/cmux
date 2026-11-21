// Scratch: measure label / clock / button text baselines in the host waiting line, per CSS arm, per engine.
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit } from "playwright";
import { preview } from "vite";
const root = path.resolve(import.meta.dir, "..");
const arms = JSON.parse(fs.readFileSync(path.join(import.meta.dir, "arms.json"), "utf8"));
import { spawnSync } from "node:child_process";
if (!fs.existsSync(path.join(root, "dist/gallery/frame.html"))) {
  const b = spawnSync("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  console.log("gallery build exit", b.status);
}
console.log("dist/gallery", fs.readdirSync(path.join(root, "dist/gallery")).slice(0, 20));
const server = await preview({ root, configFile: path.join(root, "vite.config.gallery.ts"), preview: { host: "127.0.0.1", port: 0 } });
const base = `http://127.0.0.1:${server.httpServer.address().port}`;
const measure = () => {
  const line = document.querySelector("[data-host-waiting] .acpmux-host-line, [data-host-recovering]");
  const msg = line.querySelector(".acpmux-host-line-message");
  const clock = msg.querySelector(".ui-clock");
  const btn = line.querySelector("button");
  const textRect = (node) => { const r = document.createRange(); r.selectNodeContents(node); const rs = [...r.getClientRects()]; return rs[rs.length - 1]; };
  // first text node of the message (the label)
  const labelNode = [...msg.childNodes].find((n) => n.nodeType === 3 && n.textContent.trim());
  const lr = document.createRange(); lr.selectNodeContents(labelNode); const label = lr.getBoundingClientRect();
  const c = clock ? textRect(clock.firstChild) : null;
  const b = btn ? textRect(btn.firstChild ?? btn) : null;
  return { label: { top: label.top, bottom: label.bottom }, clock: c && { top: c.top, bottom: c.bottom }, button: b && { top: b.top, bottom: b.bottom },
    clockDy: c ? +(c.bottom - label.bottom).toFixed(2) : null, buttonDy: b ? +(b.bottom - label.bottom).toFixed(2) : null,
    lineH: line.getBoundingClientRect().height, msgH: msg.getBoundingClientRect().height };
};
for (const [engineName, engine] of [["chromium", chromium], ["webkit", webkit]]) {
  let browser; try { browser = await engine.launch(); } catch (e) { console.log(JSON.stringify({ engine: engineName, error: String(e).slice(0, 200) })); continue; }
  for (const [variant, widthName] of [["waiting", "normal"], ["waiting", "narrow"]]) for (const [arm, css] of Object.entries(arms)) {
    const page = await browser.newPage({ viewport: { width: 760, height: 400 }, deviceScaleFactor: 2 });
    await page.goto(`${base}/frame.html?entry=agent-pane.host-error&variant=${variant}&width=${widthName}&frame=component&colorScheme=light`);
    try { await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 90000 }); }
    catch (e) { console.log("not ready", engineName, arm, (await page.content()).slice(0, 800)); await page.close(); continue; }
    if (css) await page.addStyleTag({ content: css });
    await page.waitForTimeout(300);
    console.log(JSON.stringify({ engine: engineName, variant, widthName, arm, ...(await page.evaluate(measure)) }));
    const out = process.env.FAST_CHECKS_OUT; if (out) { const el = page.locator("[data-host-error-fixture]"); await el.screenshot({ path: path.join(out, `${engineName}-${widthName}-${arm}.png`) }); }
    await page.close();
  }
  await browser.close();
}
server.httpServer.close();
