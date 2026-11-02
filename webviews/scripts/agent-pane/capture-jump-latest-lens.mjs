// Capture Jump to latest's fisheye lens from the real gallery entry (agent-pane.jump-latest-lens), in
// Chromium, cropped round the button: each strength, and the shared glass without the lens (before).
// Usage: bun capture-jump-latest-lens.mjs OUT_DIR [dark|light]
// Prints each PNG as CAPTURE_BASE64 lines (the fleet log carries them back) and, per variant, how
// many of the disc's pixels differ from the before capture (0 means the lens drew nothing).
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
const shots = [
  ["before", "medium"],
  ["soft", "soft"],
  ["medium", "medium"],
  ["strong", "strong"],
];
try {
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      viewport: { width: 900, height: 720 },
      deviceScaleFactor: 2,
      colorScheme: scheme,
    });
    const discs = {};
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
        () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 400)))),
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
        clip: { x: box.x + box.width / 2 - 90, y: box.y + box.height / 2 - 40, width: 180, height: 80 },
      });
      const disc = await page.screenshot({
        clip: { x: box.x + 4, y: box.y + 4, width: box.width - 8, height: box.height - 8 },
      });
      discs[name] = disc;
      const encoded = fs.readFileSync(file).toString("base64");
      console.log(JSON.stringify({ scheme, name, box, info }));
      for (let offset = 0; offset < encoded.length; offset += 2000)
        console.log(`CAPTURE_BASE64 ${path.basename(file)} ${offset} ${encoded.slice(offset, offset + 2000)}`);
      await page.close();
    }
    for (const name of ["soft", "medium", "strong"])
      console.log(`LENS_DIFF ${scheme} ${name} ${Buffer.compare(discs.before, discs[name]) === 0 ? "same" : "differs"}`);
    await context.close();
  } finally {
    await browser.close();
  }
} finally {
  await new Promise((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}
