// Frame strips and a real-time video of a gallery entry's entrance motion.
// Usage: bun scripts/gallery/entrance-strip.mjs ENTRY VARIANT[,VARIANT...] OUT_DIR [STEP_MS] [END_MS]
// Every Web Animation the page starts is recorded (Element.prototype.animate is wrapped before the page
// loads); once the gallery is ready each is paused and seeked to 0, STEP, 2*STEP ... END ms of the
// entrance's own clock, and the stage is shot at each: OUT_DIR/<variant>-strip.png (one row, labelled),
// plus OUT_DIR/<variant>.webm, the page loading and the entrance playing in real time.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const [entry, variantList, outArg, stepArg, endArg] = process.argv.slice(2);
const variants = variantList.split(",");
const out = path.resolve(outArg ?? process.env.FAST_CHECKS_OUT ?? "entrance-strips");
const step = Number(stepArg ?? 40);
const end = Number(endArg ?? 480);
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
if (!fs.existsSync(path.join(root, "dist/gallery"))) {
  const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  await new Promise((resolve, reject) => {
    build.once("error", reject);
    build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
  });
}
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const baseUrl = `http://127.0.0.1:${server.httpServer.address().port}`;
const record = () => {
  const animate = Element.prototype.animate;
  window.__entrance = [];
  Element.prototype.animate = function (...args) {
    const animation = animate.apply(this, args);
    window.__entrance.push(animation);
    return animation;
  };
};
const browser = await chromium.launch();
try {
  for (const variant of variants) {
    const query = new URLSearchParams({ entry, variant, colorScheme: "dark", width: "normal", frame: "component" });
    const url = `${baseUrl}/frame.html?${query}`;
    // The real-time video.
    const videoContext = await browser.newContext({
      viewport: { width: 640, height: 420 },
      colorScheme: "dark",
      recordVideo: { dir: path.join(out, "video-tmp"), size: { width: 640, height: 420 } },
    });
    const videoPage = await videoContext.newPage();
    await videoPage.goto(url, { waitUntil: "domcontentloaded" });
    await videoPage.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await videoPage.waitForTimeout(1200);
    const video = videoPage.video();
    await videoContext.close();
    if (video) fs.renameSync(await video.path(), path.join(out, `${variant}.webm`));
    // The strip.
    const context = await browser.newContext({
      viewport: { width: 640, height: 420 },
      deviceScaleFactor: 1,
      colorScheme: "dark",
    });
    const page = await context.newPage();
    await page.addInitScript(record);
    await page.goto(url, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    const count = await page.evaluate(() => window.__entrance.length);
    const shots = [];
    for (let t = 0; t <= end; t += step) {
      await page.evaluate((t) => {
        for (const animation of window.__entrance) {
          animation.pause();
          animation.currentTime = t;
        }
      }, t);
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => resolve())));
      shots.push([t, (await page.screenshot()).toString("base64")]);
    }
    console.log(JSON.stringify({ variant, animations: count, frames: shots.length }));
    const sheet = await page.evaluate(
      async ([shots, title]) => {
        const images = await Promise.all(
          shots.map(
            ([t, src]) =>
              new Promise((resolve) => {
                const image = new Image();
                image.onload = () => resolve([t, image]);
                image.src = `data:image/png;base64,${src}`;
              }),
          ),
        );
        const scale = 0.5;
        const w = images[0][1].width * scale;
        const h = images[0][1].height * scale;
        const columns = 7;
        const rows = Math.ceil(images.length / columns);
        const canvas = document.createElement("canvas");
        canvas.width = columns * (w + 8) + 8;
        canvas.height = 40 + rows * (h + 28);
        const g = canvas.getContext("2d");
        g.fillStyle = "#555";
        g.fillRect(0, 0, canvas.width, canvas.height);
        g.fillStyle = "#fff";
        g.font = "600 18px sans-serif";
        g.fillText(title, 8, 26);
        g.font = "14px sans-serif";
        images.forEach(([t, image], index) => {
          const x = 8 + (index % columns) * (w + 8);
          const y = 40 + Math.floor(index / columns) * (h + 28);
          g.fillText(`${t} ms`, x, y + 16);
          g.drawImage(image, x, y + 22, w, h);
        });
        return canvas.toDataURL("image/png").split(",")[1];
      },
      [shots, `${entry} / ${variant}`],
    );
    fs.writeFileSync(path.join(out, `${variant}-strip.png`), Buffer.from(sheet, "base64"));
    await context.close();
  }
} finally {
  await browser.close();
  fs.rmSync(path.join(out, "video-tmp"), { recursive: true, force: true });
  await new Promise((resolve) => server.httpServer.close(resolve));
}
