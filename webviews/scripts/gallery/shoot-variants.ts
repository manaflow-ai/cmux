// Screenshots of chosen gallery variants, in WebKit (the app's engine) and Chromium, at given widths:
// a pull request's before and after, off a Mac (no Playwright on Macs).
//
//   bun scripts/gallery/shoot-variants.ts --entry agent-pane.composer --variants a,b --widths 420,900 \
//     --out DIR [--label after] [--selector .acpmux-composer]
//
// Each shot is DIR/LABEL-ENGINE-VARIANT-WIDTH.png: the selector's box when it is on the stage, else the
// whole stage. Exit 1 when a variant fails to mount.
import { mkdirSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { chromium, webkit } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../../test/support/galleryFrame";

const { values } = parseArgs({
  options: {
    entry: { type: "string" },
    variants: { type: "string" },
    widths: { type: "string", default: "420,900" },
    out: { type: "string" },
    label: { type: "string", default: "shot" },
    selector: { type: "string", default: ".acpmux-composer" },
  },
});
if (!values.entry || !values.variants || !values.out) {
  console.error("usage: shoot-variants.ts --entry ID --variants A,B --out DIR [--widths 420,900] [--label L]");
  process.exit(2);
}
const out = path.resolve(values.out);
mkdirSync(out, { recursive: true });

const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.resolve(import.meta.dir, "../../vite.config.gallery-dev.ts"),
  server: { host: "127.0.0.1", port: 0, strictPort: false },
  logLevel: "error",
});
let failed = 0;
try {
  await vite.listen();
  const port = (vite.httpServer!.address() as { port: number }).port;
  for (const engine of [webkit, chromium]) {
    const browser = await engine.launch({ headless: true });
    try {
      await warmGalleryFrame(vite, values.entry, { browser });
      for (const width of values.widths.split(",").map(Number)) {
        const page = await browser.newPage({ viewport: { width, height: 700 }, deviceScaleFactor: 2 });
        for (const variant of values.variants.split(",")) {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(values.entry, { variant, width })}`);
          await page.waitForFunction(
            () => /^(1|error)$/.test(document.documentElement.dataset.galleryReady ?? ""),
            undefined,
            {
              timeout: 60_000,
            },
          );
          const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
          const file = path.join(out, `${values.label}-${engine.name()}-${variant}-${width}.png`);
          if (ready !== "1") {
            failed += 1;
            console.log(`FAIL ${engine.name()} ${variant} ${width}: did not mount`);
            continue;
          }
          await page.waitForTimeout(400);
          const target = page.locator(values.selector).first();
          if (await target.count()) await target.screenshot({ path: file, animations: "disabled" });
          else await page.screenshot({ path: file, animations: "disabled" });
          const tiles = await page.evaluate(() =>
            [
              ...document.querySelectorAll<HTMLImageElement>(".acpmux-attachment-image img, .acpmux-queued-image img"),
            ].map((img) => `${img.dataset.crop ?? "-"}@${getComputedStyle(img).objectPosition}`),
          );
          console.log(`shot ${path.basename(file)} tiles=${tiles.join(" ")}`);
        }
        await page.close();
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await vite.close();
}
process.exit(failed ? 1 : 0);
