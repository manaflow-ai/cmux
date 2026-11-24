import path from "node:path";
import { chromium } from "playwright";
import { preview } from "vite";
const root = process.argv[2];
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const base = `http://127.0.0.1:${(server.httpServer.address() as any).port}`;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 760, height: 1100 }, deviceScaleFactor: 2 });
p.on("console", (m) => m.type() === "error" && console.log("console:", m.text().slice(0, 200)));
for (const v of ["claude", "paper", "plush-addon", "cmux"]) {
  const t0 = Date.now();
  await p.goto(
    `${base}/frame.html?entry=looks.golden&variant=${v}&frame=component&reducedMotion=true&colorScheme=light`,
  );
  await p
    .waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 120000 })
    .catch((e) => console.log(String(e).slice(0, 100)));
  console.log(v, "ready", await p.evaluate(() => document.documentElement.dataset.galleryReady), Date.now() - t0, "ms");
}
await p.screenshot({ path: "/tmp/lcprobe/claude-light.png" });
await b.close();
server.httpServer.close();
process.exit(0);
