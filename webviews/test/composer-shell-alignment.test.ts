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
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
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

  /** The prompt's drawn line: its placeholder text, which stands where the caret does. */
  const promptLine = () => {
    const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
    const placeholder = document.querySelector(".acpmux-composer-box .acpmux-md-placeholder")!;
    const text = placeholder.querySelector(".acpmux-md-placeholder-text") ?? placeholder;
    const range = document.createRange();
    range.selectNodeContents(text);
    const rect = range.getBoundingClientRect();
    return {
      boxHeight: box.height,
      textLeft: rect.left - box.left,
      lineCenter: (rect.top + rect.bottom) / 2 - box.top,
    };
  };

  /** Shell mode's drawn line: the `!` glyph, and where the field puts the command's first character. */
  const shellLine = () => {
    const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
    const glyph = document.querySelector(".acpmux-shell-glyph")!;
    const range = document.createRange();
    range.selectNodeContents(glyph);
    const glyphRect = range.getBoundingClientRect();
    const field = document.querySelector<HTMLTextAreaElement>(".acpmux-shell-field")!;
    const fieldRect = field.getBoundingClientRect();
    const style = getComputedStyle(field);
    const padLeft = parseFloat(style.paddingLeft);
    const padTop = parseFloat(style.paddingTop);
    const lineHeight = parseFloat(style.lineHeight);
    return {
      boxHeight: box.height,
      glyphLeft: glyphRect.left - box.left,
      glyphRight: glyphRect.right - box.left,
      glyphCenter: (glyphRect.top + glyphRect.bottom) / 2 - box.top,
      // The field is a textarea: its text starts at its own padding, on a line of its own height.
      textLeft: fieldRect.left + padLeft - box.left,
      lineCenter: fieldRect.top + padTop + lineHeight / 2 - box.top,
    };
  };

  // 1 is the default; 1.25 is the largest chrome size the app and the gallery allow (gallery/env.ts).
  for (const interfaceScale of [1, 1.25])
    test(`at the ${interfaceScale} chrome size: the \`!\` glyph takes the caret's column and line`, async () => {
      const page = await browser!.newPage({ viewport: { width: 720, height: 300 } });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-row", { variant: "claude-auto", interfaceScale })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-composer-box .acpmux-md-placeholder").first().waitFor();
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
          .screenshot({ path: path.join(outDir, `shell-${interfaceScale}.png`) });
        console.log(JSON.stringify({ interfaceScale, prompt, shell }));

        const off = (a: number, b: number) => Math.abs(a - b) > TOLERANCE;
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
        // The glyph keeps its own character column: the command never prints over it.
        if (shell.textLeft < shell.glyphRight - TOLERANCE)
          problems.push(
            `the command starts ${f(shell.textLeft)} px into the box, inside the glyph, which ends at ${f(shell.glyphRight)} px`,
          );
        expect(problems).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
