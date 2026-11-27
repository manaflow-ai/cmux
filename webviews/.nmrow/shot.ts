import path from "node:path";
const { chromium } = await import(Bun.resolveSync("playwright", process.argv[2] + "/"));
const root = process.argv[2]; const out = process.argv[3];
process.chdir(root);
const { createServer } = await import(Bun.resolveSync("vite", root + "/"));
const { galleryFrame } = await import(path.join(root, "test/support/galleryFrame.ts"));
const vite = await createServer({ configFile: path.join(root, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
await vite.listen();
const port = vite.httpServer.address().port;
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ deviceScaleFactor: 2 });
const res: any[] = [];
for (const variant of ["line-worked-tokens", "line-worked", "line-working"]) {
  for (const w of [820, 640, 420, 320, 240, 180, 140]) {
    await page.setViewportSize({ width: w, height: 340 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.since-divider", { variant })}`);
    await page.locator(".cv-worked").first().waitFor();
    await page.waitForTimeout(700);
    const m = await page.evaluate(() => {
      const r = (e: Element | null) => { if (!e) return null; const b = e.getBoundingClientRect(); return { l: Math.round(b.left), r: Math.round(b.right), t: Math.round(b.top), b: Math.round(b.bottom) }; };
      const vis = (e: Element | null) => e ? getComputedStyle(e).opacity : null;
      const words = document.querySelector(".cv-since__tag-words"), nw = document.querySelector(".cv-since__tag-new");
      const label = document.querySelector(".cv-worked .cv-worked__label"); const count = document.querySelector(".cv-worked .cv-worked__count");
      const lastText = [...document.querySelectorAll(".cv-worked > *")].map(r).filter(Boolean).reduce((a: number, b: any) => Math.max(a, b.r), 0);
      return { worked: r(document.querySelector(".cv-worked")), wordsOp: vis(words), words: r(words), newOp: vis(nw), new: r(nw), tagOp: vis(document.querySelector(".cv-since__tag")), label: r(label), labelText: (label as HTMLElement)?.innerText, count: r(count), lineRight: lastText };
    });
    res.push({ variant, w, ...m });
    await page.screenshot({ path: `${out}/${variant}-${w}.png`, clip: { x: 0, y: 0, width: w, height: 340 } });
  }
}
console.log(JSON.stringify(res, null, 0).replace(/\},\{/g, "},\n{"));
await browser.close(); await vite.close();
