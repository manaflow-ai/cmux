// l10n-allow-file: benchmark capture labels, not shipped UI.
// Fleet-only before/after gallery captures of the exact same rest/hover variants.
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";
import { installPaintedFrames } from "../test/support/paintedFrames";

const root = path.resolve(import.meta.dir, "../..");
const files = ["ThreadMinimap.tsx", "threadMinimap.css"].map(
  (name) => `webviews/src/agent-session/acpmux/threadMinimap/${name}`,
);
const head = files.map((file) => fs.readFileSync(path.join(root, file)));
const base = process.argv[2] ?? "HEAD";
const browser = await chromium.launch({ headless: true });
const captures = new Map<string, Buffer>();
try {
  for (const version of ["before", "after"]) {
    for (const [index, file] of files.entries()) {
      const fixture =
        process.env.RAIL_BASE_DIR &&
        path.join(process.env.RAIL_BASE_DIR, path.basename(file).replace(/\.(tsx|css)$/, ".txt"));
      const read =
        version === "before" && !fixture ? Bun.spawnSync(["git", "show", `${base}:${file}`], { cwd: root }) : undefined;
      if (read && read.exitCode !== 0) throw new Error(read.stderr.toString());
      fs.writeFileSync(
        path.join(root, file),
        version === "before" ? (fixture ? fs.readFileSync(fixture) : read!.stdout) : head[index]!,
      );
    }
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    try {
      await vite.listen();
      await warmGalleryFrame(vite, "agent-pane.thread-minimap", { browser });
      for (const variant of ["rest", "hovered"]) {
        const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
        try {
          await installPaintedFrames(page);
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.thread-minimap", { variant, width: 1280 })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          if (variant === "hovered") await page.locator(".acpmux-minimap__card").waitFor();
          await page.evaluate(async () => {
            const start = performance.now();
            // Finite entrances/hover transitions end themselves. A nonsettling state fails.
            for (let attempt = 0; attempt < 30; attempt++) {
              await Promise.all(
                document
                  .getAnimations()
                  .filter((a) => a.effect?.getComputedTiming().endTime !== Infinity)
                  .map((a) => a.finished.catch(() => undefined)),
              );
              await window.cmuxPaintFrame();
              if (
                !document
                  .getAnimations()
                  .some((a) => a.playState === "running" && a.effect?.getComputedTiming().endTime !== Infinity)
              )
                return;
              if (performance.now() - start > 10_000) break;
            }
            throw new Error("Gallery motion did not settle");
          });
          const rail = await page.locator(".acpmux-minimap__rail").screenshot();
          captures.set(`${version}-${variant}`, rail);
          console.log(`RAIL_GALLERY ${version}-${variant} ${(await page.screenshot()).toString("base64")}`);
          if (variant === "hovered")
            captures.set(`${version}-card`, await page.locator(".acpmux-minimap__card").screenshot());
        } finally {
          await page.close();
        }
      }
    } finally {
      await vite.close();
    }
  }
  const { PNG } = createRequire(import.meta.url)("pngjs") as {
    PNG: { sync: { read(data: Buffer): { width: number; height: number; data: Buffer } } };
  };
  for (const state of ["rest", "hovered", "card"]) {
    const before = PNG.sync.read(captures.get(`before-${state}`)!);
    const after = PNG.sync.read(captures.get(`after-${state}`)!);
    const same = before.width === after.width && before.height === after.height && before.data.equals(after.data);
    console.log(
      "RAIL_GALLERY_COMPARE " +
        JSON.stringify({ state, width: before.width, height: before.height, pixelIdentical: same }),
    );
    if (!same) throw new Error(`${state} pixels changed`);
  }
} finally {
  for (const [index, file] of files.entries()) fs.writeFileSync(path.join(root, file), head[index]!);
  await browser.close();
}
