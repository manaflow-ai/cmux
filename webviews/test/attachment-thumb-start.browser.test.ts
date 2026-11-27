// An attachment thumbnail shows its picture from the start, never a slice from its middle (Leo,
// 2026-11-27: "did we fix this yet", on a composer tile and a sent one reading "or a script:
// lane-deploy" cut on both sides, and queued tiles reading "Reply 3 minut" and "ing"). The tiles are
// small `object-fit: cover` boxes; a wide screenshot of text was cut around its centre. Now every
// thumbnail (the strip's and the sent prompt's .acpmux-attachment-image, the instant preview, the
// queue's .acpmux-queued-image) keeps its left top, and its cut end fades (composer/thumbCrop.ts).
//
// The real stylesheets and the real thumbCrop.ts, in both engines: a wide picture whose first 40
// columns are red (its first words) and whose middle is blue. The tile's first pixels must be red.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { chromium, type Page, webkit } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

const root = join(import.meta.dir, "../src/agent-session/acpmux");
const css = ["composerAttachments.css", "composerStates.css"].map((file) => readFileSync(join(root, file), "utf8"));
const cropScript = new Bun.Transpiler({ loader: "ts" })
  .transformSync(readFileSync(join(root, "composer/thumbCrop.ts"), "utf8"))
  .replace(/^export /gm, "");

const PAGE = `<!doctype html><html><body style="margin:0;background:#202020">
<div style="--acpmux-attach-height:48px;--acpmux-attach-radius:8px;--agent-text:#fff;padding:20px;display:flex;gap:20px">
  <div class="acpmux-attachment acpmux-attachment-image" id="strip"><img id="strip-img"></div>
  <button class="acpmux-queued-image" id="queued"><img id="queued-img"></button>
  <div class="acpmux-attachment acpmux-attachment-image" id="tall"><img id="tall-img"></div>
</div></body></html>`;

/** A data URL of a `width`×`height` picture: red over its first 40 columns and rows, blue elsewhere. */
async function picture(page: Page, width: number, height: number): Promise<string> {
  return page.evaluate(
    ([w, h]) => {
      const canvas = document.createElement("canvas");
      canvas.width = w;
      canvas.height = h;
      const g = canvas.getContext("2d")!;
      g.fillStyle = "#0000ff";
      g.fillRect(0, 0, w, h);
      g.fillStyle = "#ff0000";
      g.fillRect(0, 0, 40, 40);
      return canvas.toDataURL("image/png");
    },
    [width, height] as const,
  );
}

/** The colour at (x, y) of the element's own screenshot, read back through a canvas. */
async function pixel(page: Page, selector: string, x: number, y: number): Promise<[number, number, number]> {
  const shot = (await page.locator(selector).screenshot({ animations: "disabled" })).toString("base64");
  return page.evaluate(
    async ([src, px, py]) => {
      const image = new Image();
      image.src = `data:image/png;base64,${src}`;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.naturalWidth;
      canvas.height = image.naturalHeight;
      const g = canvas.getContext("2d")!;
      g.drawImage(image, 0, 0);
      const [r, gr, b] = g.getImageData(px, py, 1, 1).data;
      return [r!, gr!, b!] as [number, number, number];
    },
    [shot, x, y] as const,
  );
}

const reddish = ([r, g, b]: [number, number, number]) => r > 150 && g < 90 && b < 90;

await requireBrowserLane("attachment-thumb-start.browser.test.ts", async () => {
  for (const engine of [chromium, webkit]) {
    test(`${engine.name()}: every thumbnail shows its picture's start, and a cut one says so`, async () => {
      const browser = await engine.launch({ headless: true });
      try {
        const page = await browser.newPage({ viewport: { width: 600, height: 200 }, deviceScaleFactor: 1 });
        await page.setContent(PAGE);
        for (const sheet of css) await page.addStyleTag({ content: sheet });
        await page.addScriptTag({ content: `${cropScript}\nwindow.markCrop = markCrop;` });
        // A wide screenshot strip (the tiles in Leo's shots) and a tall page.
        const wide = await picture(page, 1400, 90);
        const tall = await picture(page, 90, 1400);
        await page.evaluate(
          async ([w, t]) => {
            const load = async (id: string, src: string) => {
              const img = document.getElementById(id) as HTMLImageElement;
              img.src = src;
              await img.decode();
              (window as unknown as { markCrop(i: HTMLImageElement): void }).markCrop(img);
            };
            await load("strip-img", w);
            await load("queued-img", w);
            await load("tall-img", t);
          },
          [wide, tall] as const,
        );
        for (const id of ["strip-img", "queued-img", "tall-img"]) {
          // The picture's first words are the tile's first pixels (inside the 1px outline).
          const start = await pixel(page, `#${id}`, 4, 4);
          expect({ id, start, red: reddish(start) }).toEqual({ id, start, red: true });
          const box = await page.locator(`#${id}`).evaluate((img) => {
            const style = getComputedStyle(img);
            return { position: style.objectPosition, crop: (img as HTMLImageElement).dataset.crop };
          });
          expect({ id, start: ["0% 0%", "left top"].includes(box.position) }).toEqual({ id, start: true });
          expect({ id, crop: box.crop }).toEqual({ id, crop: id === "tall-img" ? "y" : "x" });
        }
      } finally {
        await browser.close();
      }
    });
  }
});
