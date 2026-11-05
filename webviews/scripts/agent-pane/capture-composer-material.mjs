// Capture the composer in the shared glass material (glass.css, "GLASS MATERIAL") from the real
// gallery entry (agent-pane.composer-look, the composer-material-* variants), in Chromium, over the
// colorful wallpaper on a see-through window, dark and light. "before" is the Plain variant with
// .ui-glass-material removed from the card, which is the card as feat-cmux-next drew it: every rule
// of the material needs that class.
// Usage: bun capture-composer-material.mjs OUT_DIR
// Writes <shot>-<scheme>.png (the card and its surroundings) and before-after-<scheme>.png (the two
// side by side) to OUT_DIR, and prints each shot's computed card style.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? process.env.FAST_CHECKS_OUT ?? "composer-material-captures");
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
  ["before", "composer-material-plain"],
  ["after", "composer-material-plain"],
  ["lens", "composer-material-lens"],
  ["reduce-transparency", "composer-material-reduce-transparency"],
];
try {
  const browser = await chromium.launch({ channel: "chrome" });
  try {
    for (const scheme of ["dark", "light"]) {
      const context = await browser.newContext({
        viewport: { width: 760, height: 360 },
        deviceScaleFactor: 2,
        colorScheme: scheme,
      });
      const files = {};
      for (const [name, variant] of shots) {
        const page = await context.newPage();
        const url = `${baseUrl}/frame.html?entry=agent-pane.composer-look&variant=${variant}&colorScheme=${scheme}&width=normal&frame=component`;
        await page.goto(url, { waitUntil: "domcontentloaded" });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 90_000,
        });
        await page.waitForSelector(".acpmux-composer-box.ui-glass-material", { timeout: 60_000 });
        if (name === "before")
          await page.evaluate(() =>
            document.querySelector(".acpmux-composer-box")?.classList.remove("ui-glass-material"),
          );
        await page.evaluate(
          () =>
            new Promise((resolve) =>
              requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 600))),
            ),
        );
        const box = await page.locator(".acpmux-composer-box").boundingBox();
        if (!box) throw new Error("the composer card did not render");
        const info = await page.evaluate(() => {
          const card = document.querySelector(".acpmux-composer-box");
          const style = card && getComputedStyle(card);
          return { background: style?.backgroundColor, backdrop: style?.backdropFilter, shadow: style?.boxShadow };
        });
        const viewport = page.viewportSize();
        const x = Math.max(0, box.x - 32);
        const y = Math.max(0, box.y - 40);
        const clip = {
          x,
          y,
          width: Math.min(viewport.width - x, box.width + 64),
          height: Math.min(viewport.height - y, box.height + 72),
        };
        const file = path.join(out, `${name}-${scheme}.png`);
        await page.screenshot({ path: file, clip });
        files[name] = file;
        console.log(JSON.stringify({ scheme, name, box, info }));
        await page.close();
      }
      // Before and after side by side, one PNG per scheme.
      const page = await context.newPage();
      const [before, after] = ["before", "after"].map((name) => fs.readFileSync(files[name]).toString("base64"));
      const png = await page.evaluate(
        async ([a, b]) => {
          const load = (src) =>
            new Promise((resolve, reject) => {
              const image = new Image();
              image.onload = () => resolve(image);
              image.onerror = reject;
              image.src = `data:image/png;base64,${src}`;
            });
          const [left, right] = await Promise.all([load(a), load(b)]);
          const gap = 16;
          const canvas = document.createElement("canvas");
          canvas.width = left.width + gap + right.width;
          canvas.height = Math.max(left.height, right.height);
          const context = canvas.getContext("2d");
          context.drawImage(left, 0, 0);
          context.drawImage(right, left.width + gap, 0);
          return canvas.toDataURL("image/png").split(",")[1];
        },
        [before, after],
      );
      fs.writeFileSync(path.join(out, `before-after-${scheme}.png`), Buffer.from(png, "base64"));
      await context.close();
    }
  } finally {
    await browser.close();
  }
} finally {
  await new Promise((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}
