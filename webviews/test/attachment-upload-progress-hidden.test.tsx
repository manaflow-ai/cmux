// An attachment streaming to the chat's machine shows only its ring, on its own tile (Leo,
// 2026-11-06, a picture sent under load: its loading preview drew at the composer's top left, a lone
// progress bar with a ring). The ring's `<progress>` is for assistive technology; the agent pane does
// not load the pages' global `.visually-hidden`, so a `<progress>` hidden only by that class drew as
// the native bar beside the ring. This loads the pane's own stylesheets (not the pages' styles.css)
// in Chromium and checks the bar takes no room and the ring stays inside its tile, in the strip and
// in the prompt's inline chip.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { UploadProgress } from "../src/agent-session/acpmux/composer/attachmentIntake";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("attachment-upload-progress-hidden.test.tsx", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("attachment-upload-progress-hidden: skipping (run `bunx playwright install chromium`)");
    describe.skip("upload progress", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src");
  // The pane's own sheets, as mount.tsx loads them: desktop.css first, which defines the tokens
  // (`--cmux-hairline`) the hiding class sizes itself by.
  const css = [
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/composerAttachments.css",
    "agent-session/acpmux/markdownField.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const strip = (ring: string) =>
    `<div class="acpmux-attachments"><div class="acpmux-attachment acpmux-attachment-image acpmux-attachment-pending" data-probe>${ring}</div></div>`;
  const inline = (ring: string) =>
    `<div class="acpmux-md"><p>See <span class="acpmux-md-inline-chip" data-state="loading" data-probe>${ring}</span> here</p></div>`;

  for (const [where, wrap, size] of [
    ["strip", strip, 16],
    ["inline", inline, 14],
  ] as const)
    test(`an upload's progress is its ring only (${where})`, async () => {
      const ring = renderToStaticMarkup(<UploadProgress value={0.4} name="Screenshot.png" size={size} />);
      const page = await browser!.newPage();
      await page.setContent(`<style>${css}</style>${wrap(ring)}`);
      const seen = await page.evaluate(() => {
        const tile = document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect();
        const bar = document.querySelector<HTMLElement>("progress")!.getBoundingClientRect();
        const svg = document.querySelector<SVGElement>("svg.acpmux-attachment-progress")!.getBoundingClientRect();
        return {
          bar: { width: bar.width, height: bar.height },
          ringInside:
            svg.left >= tile.left - 0.5 &&
            svg.right <= tile.right + 0.5 &&
            svg.top >= tile.top - 0.5 &&
            svg.bottom <= tile.bottom + 0.5,
        };
      });
      await page.close();
      // The bar draws nothing a person can see: at most a hairline, clipped.
      expect(seen.bar.width * seen.bar.height).toBeLessThanOrEqual(1);
      expect(seen.ringInside).toBe(true);
    });
});
