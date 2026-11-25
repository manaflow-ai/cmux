// A row's buttons sit in a fixed slot: none moves as the row's text grows or wraps. Leo,
// 2026-11-17, of a sent message's Copy right after its footer's words: "stop making the copy button
// move with the text, why was it not just at the right edge". The gallery entry
// agent-pane.row-actions-slots (RowActionsSlots.gallery.ts) draws every row kind with buttons at a
// short, a long and a wrapped text; this reads each button's offset from its row's edges in all three
// and fails on a button whose slot edge moved.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("row-actions-slots-browser.test.ts", async () => {
  const ENTRY = "src/agent-session/acpmux/conversation/RowActionsSlots.gallery.ts";
  setDefaultTimeout(360_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, `/gallery/frame.html?entryPath=${ENTRY}`, { timeoutMs: 30_000, limit: 0 });
    await warmViteServer(vite, "/src/gallery/frame/main.ts", { timeoutMs: 120_000, limit: 200 });
    await warmViteServer(vite, `/${ENTRY}`, { timeoutMs: 120_000, limit: 600 });
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Per row, each shown button's offset from the row's left and right edges, by its label.
  async function slots(variant: string): Promise<Record<string, Record<string, { left: number; right: number }>>> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
    try {
      await page.goto(
        `http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.row-actions-slots&entryPath=${ENTRY}` +
          `&variant=${variant}&colorScheme=dark&width=normal&reducedMotion=1`,
        { timeout: 300_000 },
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 60_000,
      });
      await page.evaluate(() => document.fonts.ready);
      return await page.evaluate(() =>
        Object.fromEntries(
          [...document.querySelectorAll("[data-row-id^='slot-']")].map((row) => {
            const box = row.getBoundingClientRect();
            const buttons = [
              ...row.querySelectorAll<HTMLElement>(
                ".cv-user__actions button, .cv-received-actions button, .cv-turn-actions button",
              ),
            ].filter((button) => button.getBoundingClientRect().width > 0);
            return [
              row.getAttribute("data-row-id")!,
              Object.fromEntries(
                buttons.map((button) => {
                  const at = button.getBoundingClientRect();
                  return [
                    button.getAttribute("aria-label") ?? "",
                    { left: Math.round(at.left - box.left), right: Math.round(box.right - at.right) },
                  ];
                }),
              ),
            ];
          }),
        ),
      );
    } finally {
      await page.close();
    }
  }

  test("every row's buttons keep their slot at a short, a long and a wrapped text", async () => {
    const [short, long, wrapped] = [await slots("short"), await slots("long"), await slots("wrapped")];
    console.log(`ROW_SLOTS ${JSON.stringify({ short, long, wrapped })}`);
    // The rows that must hold buttons: a sent prompt, one still sending, and a reply's footer.
    for (const id of ["slot-sent", "slot-pending", "slot-reply-summary"])
      expect(Object.keys(short[id] ?? {}).length, `${id} buttons`).toBeGreaterThan(0);
    for (const [id, buttons] of Object.entries(short)) {
      for (const [label, at] of Object.entries(buttons)) {
        // A prompt's buttons are pinned to the bubble's right edge, a reply's to its prose's left.
        const edge = id.startsWith("slot-reply") ? "left" : "right";
        for (const [name, other] of [
          ["long", long],
          ["wrapped", wrapped],
        ] as const)
          expect(other[id]?.[label]?.[edge], `${id} ${label} ${edge} edge at ${name} text`).toBe(at[edge]);
      }
    }
  });
});
