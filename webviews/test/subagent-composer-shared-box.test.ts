// A subagent's own pane draws the chat's Composer, through the same branch and wrapper as a chat
// (App.tsx `subagentRelay`, Composer.tsx `relay`), so the box sits where a chat's does, at its size
// (Leo 2026-11-22: "i notice there's differing layouts among it and normal chats... we should align
// things better"). Its own composer (SubagentComposer.tsx) drew a line naming the chat under the box,
// which moved the box up 24 px from a chat's.
// In real Chromium (Playwright; CI fails the file when it cannot launch, requireBrowserLane), on
// gallery `agent-pane.subagent-composer` at 420 and 900 px:
// - the subagent's composer is `data-cmux-component="Composer"`, relayed, with no line under it;
// - its form and box rects are the normal chat's (`chat`), with the hat and without it.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-composer-shared-box.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-composer";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "chat" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  type Rect = { x: number; y: number; width: number; height: number };
  /** The composer a variant draws once its play is done: which component, and its rects. */
  async function composerOf(variant: string, width: number) {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width, height: 640 }, reducedMotion: "reduce" });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      return await page.evaluate(() => {
        const rect = (node: Element | null): Rect | null => {
          if (!node) return null;
          const r = node.getBoundingClientRect();
          return { x: r.x, y: r.y, width: r.width, height: r.height };
        };
        const forms = document.querySelectorAll("form.acpmux-composer");
        const form = forms[0] ?? null;
        return {
          count: forms.length,
          component: form?.getAttribute("data-cmux-component") ?? null,
          relayed: form?.hasAttribute("data-composer-relay") ?? false,
          via: document.querySelectorAll(".cv-subagent-composer-via").length,
          form: rect(form),
          box: rect(form?.querySelector(".acpmux-composer-box") ?? null),
        };
      });
    } finally {
      await page.close();
    }
  }

  const near = (a: Rect | null, b: Rect | null) => {
    expect(a).not.toBeNull();
    expect(b).not.toBeNull();
    for (const key of ["x", "y", "width", "height"] as const) expect(Math.abs(a![key] - b![key])).toBeLessThan(1);
  };

  for (const width of [420, 900]) {
    for (const variant of ["subagent", "subagent-hat"]) {
      test(`${variant}: the chat's Composer, at the chat's box (${width}px)`, async () => {
        const chat = await composerOf("chat", width);
        const subagent = await composerOf(variant, width);
        expect(chat.count).toBe(1);
        expect(chat.relayed).toBe(false);
        expect(subagent.count).toBe(1);
        expect(subagent.component).toBe("Composer");
        expect(subagent.relayed).toBe(true);
        expect(subagent.via).toBe(0);
        near(subagent.box, chat.box);
        near(subagent.form, chat.form);
      });
    }
  }
});
