// l10n-allow-file: gallery fixture names are test data.
// A subagent's own composer names the chat that passes its message on ("Sent through <chat>",
// SubagentComposer.tsx). That line was drawn in ComposerBox's `bottom` host, which has no height
// and places its content 12 px over its bottom edge, over a chat's quiet row. The subagent's
// composer has no quiet row, so the line stood on the prompt's own row and its text ran over the
// placeholder ("Message Address CodeRabbit…" over "Sent through Work https://…", #45911).
// In real Chromium (Playwright; CI fails the file when it cannot launch, requireBrowserLane), on
// gallery `agent-pane.subagents` / `own-pane`:
// - the line sits under the composer box, never inside it;
// - its text and the placeholder's share no pixel row.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-composer-via-line.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagents";
  const variant = "own-pane";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const width of [760, 360]) {
    test(`the "Sent through" line is its own row under the box, clear of the placeholder (${width}px)`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({ viewport: { width, height: 640 }, reducedMotion: "reduce" });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-subagent-composer .cv-subagent-composer-via").waitFor();
        const layout = await page.evaluate(() => {
          const composer = document.querySelector(".acpmux-subagent-composer")!;
          const rect = (node: Element | Range) => {
            const r = node.getBoundingClientRect();
            return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
          };
          const via = composer.querySelector(".cv-subagent-composer-via")!;
          const placeholder = composer.querySelector(".acpmux-md-placeholder")!;
          const text = placeholder.querySelector(".acpmux-md-placeholder-text") ?? placeholder;
          const range = document.createRange();
          range.selectNodeContents(text);
          return {
            box: rect(composer.querySelector(".acpmux-composer-box")!),
            via: rect(via),
            viaText: via.textContent ?? "",
            placeholder: rect(range),
            placeholderText: text.textContent ?? "",
          };
        });
        expect(layout.viaText).toStartWith("Sent through ");
        expect(layout.placeholderText).toBe("Message Test coverage");
        // Under the box, not over its bottom.
        expect(layout.via.top).toBeGreaterThanOrEqual(layout.box.bottom - 0.5);
        // No pixel row holds both texts.
        expect(layout.via.top).toBeGreaterThanOrEqual(layout.placeholder.bottom - 0.5);
      } finally {
        await page.close();
      }
    });
  }
});
