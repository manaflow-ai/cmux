// A dropped screen recording's chip in real Chromium (Leo 2026-10-22: "the screen reccording preview
// is just a file name"): the composer takes the gallery's 3 s colour-bar .mov the way a drop does
// (intakeFiles, with the host answering where it is), the page decodes it, and the chip shows a
// JPEG poster of the real frame (the bars' grey, not black) with "0:03" beside the play glyph.
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { COLOR_BARS_MOV } from "../src/gallery/fixtures/videoFixtures";

await requireBrowserLane("composer-video-chip-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("composer-video-chip-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer video chip", () => test("chromium", () => {}));
    return;
  }
  const source = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
  const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "composer-video-chip-")), "entry.tsx");
  // The entry is outside the package: React resolves from here.
  const module = (name: string) => JSON.stringify(Bun.resolveSync(name, import.meta.dir));
  fs.writeFileSync(
    entry,
    `import { createElement } from ${module("react")};
     import { createRoot } from ${module("react-dom/client")};
     import { flushSync } from ${module("react-dom")};
     import { intakeFiles } from ${JSON.stringify(path.join(source, "composer/intakeFiles.ts"))};
     import { AttachmentStrip } from ${JSON.stringify(path.join(source, "composer/attachmentIntake.tsx"))};
     Object.assign(window, {
       async drop(base64, name) {
         const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
         const file = new File([bytes], name, { type: "video/quicktime" });
         const taken = await intakeFiles([file], {
           held: 0,
           allowImages: true,
           localPaths: async () => [{ path: "/Users/you/Desktop/" + name, folder: false }],
         });
         const root = createRoot(document.getElementById("root"));
         flushSync(() => root.render(createElement(AttachmentStrip, { attachments: taken.attachments, onRemove() {} })));
         return taken.attachments.map(({ poster, ...rest }) => ({ ...rest, poster: poster?.slice(0, 23) }));
       },
     });`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  fs.rmSync(path.dirname(entry), { recursive: true, force: true });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs.find((output) => output.path.endsWith(".js"))!.text();

  describe("a dropped .mov's chip", () => {
    test("shows a poster of its real frame and its length", async () => {
      const page = await browser.newPage();
      try {
        await page.setContent(`<!doctype html><html><body><div id="root"></div></body></html>`);
        await page.addScriptTag({ content: script });
        const name = "Screen Recording 2026-10-22 at 21.41.07.mov";
        const attachments = await page.evaluate(
          ([base64, file]) =>
            (window as unknown as { drop(b: string, n: string): Promise<unknown> }).drop(base64!, file!),
          [COLOR_BARS_MOV, name],
        );
        expect(attachments).toEqual([
          {
            id: `link:/Users/you/Desktop/${name}`,
            kind: "link",
            name,
            mimeType: "",
            size: 0,
            path: `/Users/you/Desktop/${name}`,
            poster: "data:image/jpeg;base64,",
            duration: 3,
          },
        ]);
        const chip = await page.evaluate(async () => {
          const img = document.querySelector<HTMLImageElement>(".acpmux-attachment-video-frame img")!;
          await img.decode();
          // The bars' top-left: 75% grey, not a black frame the decoder never drew.
          const canvas = document.createElement("canvas");
          canvas.width = img.naturalWidth;
          canvas.height = img.naturalHeight;
          const context = canvas.getContext("2d")!;
          context.drawImage(img, 0, 0);
          const [r, g, b] = context.getImageData(4, 4, 1, 1).data;
          return {
            size: [img.naturalWidth, img.naturalHeight],
            pixel: [r, g, b],
            length: document.querySelector(".acpmux-attachment-video-length")?.textContent,
            play: Boolean(document.querySelector(".acpmux-attachment-video .acpmux-attachment-video-play")),
            fileChip: Boolean(document.querySelector(".acpmux-attachment-file")),
          };
        });
        expect(chip.size).toEqual([192, 108]);
        for (const channel of chip.pixel) expect(channel).toBeGreaterThan(150);
        expect(chip.length).toBe("0:03");
        expect(chip.play).toBe(true);
        expect(chip.fileChip).toBe(false);
      } finally {
        await page.close();
      }
    });
    test("closes the browser", async () => {
      await browser.close();
    });
  });
});
