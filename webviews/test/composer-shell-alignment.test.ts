// Shell mode takes the prompt's own line and column, at any chrome size: typing `!` turns the
// prompt into the shell field behind its `!` glyph (composerStates.css, composerLocation.css), and
// the comment on both says "entering or leaving moves nothing". The glyph stands on the column the
// caret had and the command's first line is the line the prompt's was, so the box neither grows nor
// shifts the text. The prompt's insets follow the chrome scale; the shell field's were literal px,
// so at the 1.25 chrome size the glyph and the shell caret stayed where scale 1 put them and the
// line moved (2.75 px down, 1.75 px left) when the mode changed.
//
// Measured in Chromium on the gallery's composer row (agent-pane.composer-row, the idle chat with
// an empty prompt), the same stage composer-alignment-centers.test.ts measures, at the chrome sizes
// the app offers (DesignSettings.interfaceScale, clamped as the gallery clamps it). A still of each
// goes to webviews/artifacts/composer-shell-alignment/ (the fleet step returns them).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-shell-alignment.test.ts", async () => {
  /** Half a pixel: the subpixel rounding a scaled inset and a text range can show. */
  const TOLERANCE = 0.5;
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-shell-alignment: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer shell alignment", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const outDir = path.join(webviews, "artifacts", "composer-shell-alignment");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-row", { browser, params: { variant: "claude-auto" } });
    mkdirSync(outDir, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  // Each line below is a field's own first line box, read the same way on both sides: the field's
  // box, its padding, and half a line down from it. A text range measures the font's content area
  // instead, which the prompt's UI font and the shell's monospace sit differently inside the same
  // line box, so a range on one side and a line box on the other report 0.875 px in Chromium that
  // nothing draws. The glyph is absolutely positioned, so its own box is its line box.

  /** The line and the column the prompt's caret sits on. */
  const promptLine = () => {
    const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
    const field = document.querySelector(".acpmux-composer-box .acpmux-md-field")!;
    const rect = field.getBoundingClientRect();
    const style = getComputedStyle(field);
    const placeholder = document.querySelector(".acpmux-composer-box .acpmux-md-placeholder")!;
    const text = placeholder.querySelector(".acpmux-md-placeholder-text") ?? placeholder;
    const range = document.createRange();
    range.selectNodeContents(text);
    return {
      boxHeight: box.height,
      textLeft: rect.left + parseFloat(style.paddingLeft) - box.left,
      lineCenter: rect.top + parseFloat(style.paddingTop) + parseFloat(style.lineHeight) / 2 - box.top,
      /// Diagnostic: the placeholder's own text, drawn on that line and column.
      placeholderLeft: range.getBoundingClientRect().left - box.left,
    };
  };

  /** Shell mode's line: the `!` glyph, and where the field puts the command's first character. */
  const shellLine = () => {
    const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
    const glyphRect = document.querySelector(".acpmux-shell-glyph")!.getBoundingClientRect();
    const field = document.querySelector<HTMLTextAreaElement>(".acpmux-shell-field")!;
    const rect = field.getBoundingClientRect();
    const style = getComputedStyle(field);
    // One character cell of the field's own font, measured in it: the glyph's column is 2ch of this.
    const probe = document.createElement("span");
    probe.style.font = style.font;
    probe.style.position = "absolute";
    probe.style.whiteSpace = "pre";
    probe.textContent = "00000000";
    document.body.append(probe);
    const cell = probe.getBoundingClientRect().width / 8;
    probe.remove();
    return {
      boxHeight: box.height,
      glyphLeft: glyphRect.left - box.left,
      glyphRight: glyphRect.right - box.left,
      glyphCenter: (glyphRect.top + glyphRect.bottom) / 2 - box.top,
      // The field is a textarea: its text starts at its own padding, on a line of its own height.
      textLeft: rect.left + parseFloat(style.paddingLeft) - box.left,
      lineCenter: rect.top + parseFloat(style.paddingTop) + parseFloat(style.lineHeight) / 2 - box.top,
      cell,
      /// Its floor, and the one line in its own insets that the floor must be: the two come from the
      /// same inset or the field stands taller than the prompt wherever a rule moves one of them
      /// (the attachments' band moves the top inset, composerAttachments.css).
      minHeight: parseFloat(style.minHeight),
      oneLine: parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) + parseFloat(style.lineHeight),
    };
  };

  /** Pastes one PNG into the prompt, as ⌘V of a copied image does: the attachments' band shows. */
  const pasteImage = (page: Page) =>
    page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 120;
      canvas.height = 80;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#101114";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      document
        .querySelector(".acpmux-composer-box .acpmux-md")!
        .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });

  // The chrome sizes the app offers (1 the default, 1.25 the largest the gallery allows,
  // gallery/env.ts), the Chat Display sizes composer-content-font.test.ts exercises (the glyph's
  // column follows the font, so 28 px is where a column written in px prints the command over it),
  // and the attachments' band, which moves the prompt's top inset: the band is the state where a
  // height written from an inset the band does not move leaves the field taller than the prompt.
  const cases = [
    { interfaceScale: 1 },
    { interfaceScale: 1.25 },
    { interfaceScale: 1, fontSize: 28 },
    { interfaceScale: 1, attachment: true },
    { interfaceScale: 1.25, attachment: true },
  ];
  for (const { interfaceScale, fontSize, attachment } of cases)
    test(`at the ${interfaceScale} chrome size${fontSize ? `, ${fontSize} px text` : ""}${attachment ? ", under an attachment" : ""}: the \`!\` glyph takes the caret's column and line`, async () => {
      const page = await browser!.newPage({ viewport: { width: 720, height: 300 } });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-row", { variant: "claude-auto", interfaceScale })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-composer-box .acpmux-md-placeholder").first().waitFor();
        if (fontSize !== undefined)
          await page.evaluate(async (size) => {
            // The gallery serves the module at this URL; a literal would be a path tsc resolves
            // (composer-content-font.test.ts takes the same step).
            const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
            const { setChatDisplay } = await import(modulePath);
            setChatDisplay({ "agentPane.display.font.size": size });
          }, fontSize);
        if (attachment) {
          // The band is Settings' attachment strip; the default inline view puts the image in the
          // prompt's line, where the prompt is no longer empty and `!` is text.
          await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "strip" }));
          await pasteImage(page);
          await page.locator(".acpmux-attachments .acpmux-attachment").first().waitFor();
        }
        await page.evaluate(() => document.fonts.ready);
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        const prompt = await page.evaluate(promptLine);

        // `!` as the first character of an empty prompt: shell mode, in place (Composer.tsx).
        await page.locator(".acpmux-composer-box .acpmux-md").first().click();
        await page.keyboard.type("!");
        await page.locator(".acpmux-shell-field").waitFor();
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        const shell = await page.evaluate(shellLine);

        // The still is the evidence whether or not the numbers pass.
        await page
          .locator(".acpmux-composer")
          .first()
          .screenshot({
            path: path.join(
              outDir,
              `shell-${interfaceScale}${fontSize ? `-${fontSize}` : ""}${attachment ? "-attachment" : ""}.png`,
            ),
          });
        console.log(JSON.stringify({ interfaceScale, fontSize, attachment, prompt, shell }));

        // A measurement that is not a number is a difference, not a pass: `min-height: auto` parses
        // as NaN, and `NaN > tolerance` is false.
        const off = (a: number, b: number) => !(Math.abs(a - b) <= TOLERANCE);
        const f = (n: number) => n.toFixed(2);
        const problems: string[] = [];
        if (off(shell.boxHeight, prompt.boxHeight))
          problems.push(`the box is ${f(shell.boxHeight)} px in shell mode, ${f(prompt.boxHeight)} px with the prompt`);
        if (off(shell.glyphCenter, prompt.lineCenter))
          problems.push(
            `the glyph's line center is ${f(shell.glyphCenter)} px into the box, the prompt's line ${f(prompt.lineCenter)} px`,
          );
        if (off(shell.glyphLeft, prompt.textLeft))
          problems.push(
            `the glyph starts ${f(shell.glyphLeft)} px into the box, the prompt's text ${f(prompt.textLeft)} px`,
          );
        if (off(shell.lineCenter, prompt.lineCenter))
          problems.push(
            `the command's line center is ${f(shell.lineCenter)} px into the box, the prompt's line ${f(prompt.lineCenter)} px`,
          );
        // The glyph keeps one character cell of the field's own font, so the command clears it at
        // every text size: a column in px is the one that prints over the glyph at 28 px.
        if (off(shell.textLeft - shell.glyphLeft, 2 * shell.cell))
          problems.push(
            `the command starts ${f(shell.textLeft - shell.glyphLeft)} px after the glyph, not the ${f(2 * shell.cell)} px of its two character cells`,
          );
        if (shell.textLeft < shell.glyphRight - TOLERANCE)
          problems.push(
            `the command starts ${f(shell.textLeft)} px into the box, inside the glyph, which ends at ${f(shell.glyphRight)} px`,
          );
        if (off(shell.minHeight, shell.oneLine))
          problems.push(
            `the field's floor is ${f(shell.minHeight)} px, not the ${f(shell.oneLine)} px one line in the insets it draws with`,
          );
        expect(problems).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
