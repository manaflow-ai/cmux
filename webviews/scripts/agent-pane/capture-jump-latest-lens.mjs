// Capture Jump to latest's fisheye lens from the real gallery entry (agent-pane.jump-latest-lens), in
// Chromium, cropped round the button: each strength, and the shared glass without the lens (before).
// Usage: bun capture-jump-latest-lens.mjs OUT_DIR [dark|light] [VARIANT,...]
// With variants, it captures those (the glass levels: level-clear,level-composer,...) instead of the
// strengths; the first is compared with the rest.
// Writes each PNG to OUT_DIR, prints one JPEG sheet of the four discs as SHEET lines (a fleet log's
// tail carries it back) and, per variant, whether its disc differs from the before capture (same
// means the lens drew nothing).
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? "jump-latest-lens-captures");
const scheme = process.argv[3] === "light" ? "light" : "dark";
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
if (!fs.existsSync(path.join(root, "dist/gallery")) || process.env.CMUX_CAPTURE_BUILD === "1") {
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
const address = server.httpServer.address();
if (!address || typeof address === "string") throw new Error("gallery preview did not bind a TCP port");
const baseUrl = `http://127.0.0.1:${address.port}`;
const picked = process.argv[4]?.split(",").filter(Boolean);
const shots = picked?.length
  ? picked.map((variant) => [variant, variant])
  : [
      ["before", "medium"],
      ["soft", "soft"],
      ["medium", "medium"],
      ["strong", "strong"],
    ];
try {
  const browser = await chromium.launch({ channel: "chrome" });
  try {
    const context = await browser.newContext({
      viewport: { width: 900, height: 720 },
      deviceScaleFactor: 2,
      colorScheme: scheme,
    });
    const discs = {};
    /** Each shot's disc and its surroundings, 56 css px square, for one small sheet in the log. */
    const sheet = [];
    for (const [name, variant] of shots) {
      const page = await context.newPage();
      const url = `${baseUrl}/frame.html?entry=agent-pane.jump-latest-lens&variant=${variant}&colorScheme=${scheme}&width=normal&frame=component`;
      await page.goto(url, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 90_000,
      });
      await page.waitForSelector(".acpmux-jump-latest[data-shown]", { timeout: 60_000 });
      if (name === "before")
        await page.evaluate(() => document.querySelector(".acpmux-jump-latest")?.classList.remove("ui-glass-fisheye"));
      await page.evaluate(
        () =>
          new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 400)))),
      );
      const box = await page.locator(".acpmux-jump-latest").boundingBox();
      if (!box) throw new Error("Jump to latest did not render");
      const info = await page.evaluate(() => {
        const button = document.querySelector(".acpmux-jump-latest");
        const style = button && getComputedStyle(button);
        return {
          backdrop: style?.backdropFilter,
          background: style?.backgroundColor,
          filters: [...document.querySelectorAll("filter[id^='cmux-glass-fisheye']")].map((f) => f.id),
        };
      });
      const file = path.join(out, `${name}-${scheme}.png`);
      await page.screenshot({
        path: file,
        clip: { x: box.x + box.width / 2 - 120, y: box.y + box.height / 2 - 48, width: 240, height: 96 },
      });
      const disc = await page.screenshot({
        clip: { x: box.x + 4, y: box.y + 4, width: box.width - 8, height: box.height - 8 },
      });
      discs[name] = disc;
      sheet.push(
        await page.screenshot({
          clip: { x: box.x + box.width / 2 - 28, y: box.y + box.height / 2 - 28, width: 56, height: 56 },
        }),
      );
      console.log(JSON.stringify({ scheme, name, box, info }).slice(0, 300));
      await page.close();
    }
    const first = shots[0][0];
    for (const [name] of shots.slice(1))
      console.log(
        `LENS_DIFF ${scheme} ${name} ${Buffer.compare(discs[first], discs[name]) === 0 ? "same" : "differs"}`,
      );
    // One JPEG of the four discs side by side (before, soft, medium, strong), short lines so a
    // fleet log's tail carries it whole: SHEET <scheme> <offset> <base64>.
    const page = await context.newPage();
    const jpeg = await page.evaluate(
      async (pngs) => {
        const images = await Promise.all(
          pngs.map(
            (src) =>
              new Promise((resolve, reject) => {
                const image = new Image();
                image.onload = () => resolve(image);
                image.onerror = reject;
                image.src = `data:image/png;base64,${src}`;
              }),
          ),
        );
        const canvas = document.createElement("canvas");
        canvas.width = images.reduce((sum, image) => sum + image.width, 0);
        canvas.height = images[0].height;
        const context = canvas.getContext("2d");
        let x = 0;
        for (const image of images) {
          context.drawImage(image, x, 0);
          x += image.width;
        }
        return canvas.toDataURL("image/jpeg", 0.8).split(",")[1];
      },
      sheet.map((buffer) => buffer.toString("base64")),
    );
    fs.writeFileSync(path.join(out, `sheet-${scheme}.jpg`), Buffer.from(jpeg, "base64"));
    for (let offset = 0; offset < jpeg.length; offset += 320)
      console.log(`SHEET ${scheme} ${offset} ${jpeg.slice(offset, offset + 320)}`);
    await context.close();
  } finally {
    await browser.close();
  }
} finally {
  await new Promise((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}
