// cmux-web-test-timeout: 600
// Chat cards at narrow widths (Leo 2026-11-22: "overlapping text via the buttosn when the pane is
// small. ok, so simply prepare for this scenario beforehand and lay things out better. below the
// potentially long text, etc. or make the thing bigger. whatever. and be able to shrink down to
// icons."). The rule is src/agent-session/acpmux/conversation/cardFit.css. At 240, 320, 420 and
// 640 px every card with text and buttons is checked by cardFitProblems (cardFitCheck.ts): no text
// run under a button, no button over another, nothing past the card's right edge. The
// agent-pane.card-fit entry's own variants play the check; the other cards' own gallery entries are
// loaded as they are and the same check runs over the page. The edited-files card's three layouts
// are asserted too: one row at 640, actions under the title at 320, Undo shrunk to its icon at 240.
// With FAST_CHECKS_OUT set it keeps stills of the edited-files card at 640, 320, 240 and its open
// diff at 420.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { cardFitProblems } from "../src/agent-session/acpmux/cardFitCheck";
import { galleryFrame, reloaded, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-card-fit.test.ts", async () => {
  const WIDTHS = [240, 320, 420, 640];
  const HEIGHT = 640;
  const OWN = "agent-pane.card-fit";
  const OWN_VARIANTS = ["edited-long-name", "edited-many", "edited-diff-open", "permission", "subagent"];
  // The other cards with text and buttons, in their own gallery entries as they are.
  const OTHERS: [entry: string, variant: string][] = [
    ["agent-pane.edited-files", "one-file"],
    ["agent-pane.edited-files", "three-files"],
    ["agent-pane.permission-card", "long-rule"],
    ["agent-pane.permission-card", "four-options"],
    ["ui.notice", "card"],
    ["agent-pane.background-task-card", "long-command"],
    ["agent-pane.background-task-card", "finished-collapsed"],
    ["agent-pane.trust-ask", "ask-repo"],
    ["agent-pane.share-nudge", "card"],
    ["agent-pane.share-nudge", "line"],
    ["agent-pane.managed-banner", "long-name"],
    ["agent-pane.cloud-chat-hint", "card"],
    ["agent-pane.cloud-chat-hint", "line"],
    ["agent-pane.suggested-tasks", "open"],
    ["agent-pane.suggested-tasks", "single"],
    ["agent-pane.prompt-coach", "card"],
    ["agent-pane.memory-offer", "diff"],
    ["agent-pane.preset-approval", "card"],
    ["agent-pane.queued-agent-messages", "eleven"],
    ["agent-pane.incoming-message", "long"],
    ["agent-pane.host-error", "reconnecting"],
    ["agent-pane.render-card", "chart"],
    ["agent-pane.child-ask", "line"],
    ["agent-pane.composer", "steer-waiting-stack"],
  ];

  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-card-fit: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat card fit", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const shots = process.env.FAST_CHECKS_OUT ? path.join(process.env.FAST_CHECKS_OUT, "chat-card-fit") : undefined;
  if (shots) mkdirSync(shots, { recursive: true });

  const url = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  /** A stage at `width`, mounted and played; the caller closes it. */
  const open = async (entry: string, variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: HEIGHT } });
    for (let attempt = 1; ; attempt++) {
      try {
        await page.goto(url(entry, variant));
        await page.waitForFunction(() => {
          const ready = document.documentElement.dataset.galleryReady;
          return ready === "1" || ready === "error";
        });
        break;
      } catch (error) {
        // Vite's dependency optimizer can reload the first page while it compiles.
        if (attempt === 3 || !reloaded(error)) throw error;
      }
    }
    return page;
  };
  const stageError = (page: Page) =>
    page.evaluate(() =>
      document.documentElement.dataset.galleryReady === "error"
        ? document.body.innerText.trim().slice(0, 300) || "the stage failed to mount"
        : undefined,
    );
  const check = (page: Page) => page.evaluate(`(${cardFitProblems.toString()})(document)`) as Promise<string[]>;

  /** At most `limit` pages at a time. */
  async function pool<T, R>(items: T[], limit: number, run: (item: T) => Promise<R>): Promise<R[]> {
    const out: R[] = new Array(items.length);
    let next = 0;
    await Promise.all(
      Array.from({ length: Math.min(limit, items.length) }, async () => {
        while (next < items.length) {
          const index = next++;
          out[index] = await run(items[index]!);
        }
      }),
    );
    return out;
  }

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test renders each state once (and a shared host can be out of inotify watches).
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [OWN, ...new Set(OTHERS.map(([entry]) => entry))], { browser, timeoutMs: 240_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of WIDTHS)
    test(`the card-fit variants hold at ${width} px`, async () => {
      const failures = (
        await pool(OWN_VARIANTS, 4, async (variant) => {
          const page = await open(OWN, variant, width);
          try {
            const error = await stageError(page);
            if (error) return [`${variant}: ${error}`];
            await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
            const report = await page.evaluate(() =>
              JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
            );
            if (
              shots &&
              (variant === "edited-long-name" ? width !== 420 : variant === "edited-diff-open" && width === 420)
            )
              await page.screenshot({ path: path.join(shots, `${variant}-${width}.png`) });
            return playFailures(report).map((failure) => `${variant}: ${failure}`);
          } finally {
            await page.close();
          }
        })
      ).flat();
      expect(failures).toEqual([]);
    });

  for (const width of WIDTHS)
    test(`the other chat cards hold at ${width} px`, async () => {
      const failures = (
        await pool(OTHERS, 4, async ([entry, variant]) => {
          const page = await open(entry, variant, width);
          try {
            const error = await stageError(page);
            if (error) return [`${entry}/${variant}: ${error}`];
            // Whatever the variant plays has run when the stage is ready; let the last frame paint.
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            return (await check(page)).map((problem) => `${entry}/${variant}: ${problem}`);
          } finally {
            await page.close();
          }
        })
      ).flat();
      expect(failures).toEqual([]);
    });

  /** The edited-files card's title, Undo and its label, measured at `width`. */
  const editedLayout = async (width: number) => {
    const page = await open(OWN, "edited-long-name", width);
    try {
      await page.waitForSelector(".acpmux-edited.cv-fit .acpmux-edited-head button.acpmux-edited-undo", {
        timeout: 10_000,
      });
      return await page.evaluate(() => {
        const box = (selector: string) => {
          const element = document.querySelector(selector);
          if (!element) throw new Error(`no ${selector}`);
          const rect = element.getBoundingClientRect();
          return { top: rect.top, bottom: rect.bottom, width: rect.width };
        };
        const undo = document.querySelector(".acpmux-edited button.acpmux-edited-undo")!;
        return {
          title: box(".acpmux-edited .acpmux-edited-name"),
          undo: box(".acpmux-edited button.acpmux-edited-undo"),
          label: box(".acpmux-edited button.acpmux-edited-undo .cv-fit-label"),
          aria: undo.getAttribute("aria-label"),
          chevron: Boolean(document.querySelector(".acpmux-edited .acpmux-edited-chevron")),
        };
      });
    } finally {
      await page.close();
    }
  };

  test("the edited-files card: one row at 640, actions under the title at 320, icons at 240", async () => {
    const wide = await editedLayout(640);
    // Undo starts on the title's line.
    expect(wide.undo.top).toBeLessThan(wide.title.bottom);
    expect(wide.undo.bottom).toBeGreaterThan(wide.title.top);
    expect(wide.label.width).toBeGreaterThan(0);
    expect(wide.chevron).toBe(true);
    const under = await editedLayout(320);
    expect(under.undo.top).toBeGreaterThanOrEqual(under.title.bottom - 1);
    expect(under.label.width).toBeGreaterThan(0);
    const icons = await editedLayout(240);
    expect(icons.label.width).toBe(0);
    expect(icons.aria).toBe("Undo");
  });
});
