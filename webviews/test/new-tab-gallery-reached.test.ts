// cmux-web-test-timeout: 180
// These are mounted New Tab gallery interactions: a rendered screenshot alone can miss a thrown
// play, so keep the final play receipt and the user-visible state together.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-gallery-reached.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const entries = ["agent-pane.new-tab-headline", "agent-pane.new-tab", "agent-pane.chat-cards-loading"];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entries, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [entry, variant] of [
    ["agent-pane.new-tab-headline", "picked"],
    ["agent-pane.new-tab-headline", "picker-open"],
    ["agent-pane.new-tab", "empty"],
    ["agent-pane.new-tab", "chats-loading"],
    ["agent-pane.new-tab", "attachment-menu"],
    ["agent-pane.new-tab", "style-switch"],
  ] as const) {
    test(`${entry}#${variant} reaches its mounted interaction`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
        await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
          timeout: 90_000,
        });
        const receipt = await page.evaluate(() => ({
          ready: document.documentElement.dataset.galleryReady,
          report: (
            window as unknown as {
              cmuxGalleryPlayReport?: {
                status?: string;
                error?: string;
                steps?: Array<{
                  step?: string;
                  layoutShift?: number;
                  problems?: string[];
                  popupProblems?: string[];
                  anchorMoves?: unknown[];
                }>;
              };
            }
          ).cmuxGalleryPlayReport,
          headline: document.querySelector(".nt-headline-text")?.textContent ?? "",
          menu: document.querySelector(".acpmux-project-menu") !== null,
          attach: document.querySelector('.acpmux-newtab-plus [data-value="add.files"]') !== null,
          multi: document.querySelector<HTMLInputElement>(".nt-composer .acpmux-attach-input")?.multiple ?? false,
          chatsLoading: document.querySelector(".nt-cards[aria-busy=true]") !== null,
          chatPlaceholders: document.querySelectorAll(".nt-cards[aria-busy=true] .nt-card").length,
          chatsEmpty: document.querySelector(".nt-chats-empty")?.textContent ?? "",
          threads: document.querySelector(".nt-style input[value=threads]:checked") !== null,
        }));
        expect(receipt.ready).toBe("1");
        expect(receipt.report?.error).toBeUndefined();
        const steps = receipt.report?.steps ?? [];
        // State fixtures wait for their content; only interaction plays record input steps.
        if (variant !== "empty" && variant !== "chats-loading") expect(steps.length).toBeGreaterThan(0);
        for (const step of steps) {
          expect(step.popupProblems ?? []).toEqual([]);
          expect(step.anchorMoves ?? []).toEqual([]);
        }
        // Graded as every play test is (support/galleryPlay.ts): a thrown play, a moved anchor and a
        // unexpected layout shift fail it; the runner's frame timing does not (cx-mfkky).
        // The headline play measures stable slots and its menu anchor while the footer's
        // content-sized project chevron follows the newly selected label.
        if (variant !== "empty" && variant !== "chats-loading")
          expect(playFailures(JSON.stringify(receipt.report))).toEqual([]);
        if (variant === "picked" || variant === "picker-open") {
          expect(receipt.headline).toContain("cmux");
          expect(receipt.menu).toBe(variant === "picker-open");
        }
        if (variant === "attachment-menu") {
          expect(receipt.attach).toBe(true);
          expect(receipt.multi).toBe(true);
        }
        if (variant === "empty") {
          expect(receipt.chatsLoading).toBe(false);
          expect(receipt.chatsEmpty).toBe("No chats yet");
        }
        if (variant === "chats-loading") {
          expect(receipt.chatsLoading).toBe(true);
          expect(receipt.chatPlaceholders).toBe(3);
          expect(receipt.chatsEmpty).toBe("");
        }
        if (variant === "style-switch") expect(receipt.threads).toBe(true);
      } finally {
        await page.close();
      }
    });
  }

  for (const variant of ["cards", "list"] as const) {
    test(`recent chat ${variant} placeholders preserve row heights and metadata positions`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 620, height: 420 } });
      try {
        const geometry = async (state: "loaded" | "pending") => {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-cards-loading", { variant: `${state}-${variant}` })}`,
          );
          await page.waitForSelector(".nt-card");
          return page.locator(".nt-card").evaluateAll((rows) =>
            rows.map((row) => {
              const rect = (selector: string) => row.querySelector(selector)!.getBoundingClientRect();
              return {
                height: row.getBoundingClientRect().height,
                titleLeft: rect(".nt-card-title").left,
                metaLeft: rect(".nt-card-meta").left,
                ageLeft: rect(".nt-card-age").left,
                ageRight: rect(".nt-card-age").right,
              };
            }),
          );
        };
        const loaded = await geometry("loaded");
        const pending = await geometry("pending");
        expect(loaded).toHaveLength(3);
        expect(pending).toHaveLength(3);
        for (let index = 0; index < loaded.length; index++) {
          expect(pending[index]!.height).toBeCloseTo(loaded[index]!.height, 0);
          expect(pending[index]!.titleLeft).toBeCloseTo(loaded[index]!.titleLeft, 0);
          expect(pending[index]!.metaLeft).toBeCloseTo(loaded[index]!.metaLeft, 0);
          expect(pending[index]!.ageLeft).toBeCloseTo(loaded[index]!.ageLeft, 0);
          // Only list ages occupy a fixed column; card ages size to their text.
          if (variant === "list") expect(pending[index]!.ageRight).toBeCloseTo(loaded[index]!.ageRight, 0);
        }
      } finally {
        await page.close();
      }
    });
  }
});
