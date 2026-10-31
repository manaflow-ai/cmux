// l10n-allow-file: test fixture prompts, answers and agent names, not shipped UI.
// Another agent's message opened or closed never moves the reader's view (Leo 2026-10-21: "it
// shouldnt move your scroll or whatever, just expand the area at the bottom and you're in the same
// place ... also these all need animations for expand and collapse!"), in a real layout: the line
// clicked (the message's one disclosure line, or its Details) stays on the pixel it was clicked at
// through every frame, the panel with the whole message folds open below it and back, Details folds
// in and out, and under Reduce Motion they change at once, still in place.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("received-message-fold-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("received-message-fold-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("received message fold", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const paragraphs = (count: number) =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down.",
    ).join("\n\n");
  const turn = (index: number): Row[] => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", paragraphs(2)),
  ];
  const done = Array.from({ length: 8 }, (_, index) => turn(index)).flat();
  /// Another agent's message: long enough that opening it whole reaches past the view's end, with
  /// the envelope it came in behind Details.
  const messageText = paragraphs(6);
  const received = row("msg", "user", messageText, {
    incoming: {
      kind: "message",
      message: {
        name: "Grid fix",
        text: messageText,
        raw: `<cmux-agent-message from="Grid fix">\n${messageText}\n</cmux-agent-message>`,
      },
    },
  });
  /// The reply under the message: enough that closing it leaves the view away from the end.
  const after = row("after", "assistant", paragraphs(8));

  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  /// Resolves once the view is at rest: no fold running, and three painted frames in a row show the
  /// transcript scrolled and sized as the frame before.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const moving = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  const atLatest = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
  /// Marks the element `selector` finds, so later reads follow it across re-renders of its row.
  const probe = (page: Page, selector: string) =>
    page.evaluate((query) => {
      document.querySelector("[data-probe]")?.removeAttribute("data-probe");
      document.querySelector<HTMLElement>(query)!.dataset.probe = "true";
    }, selector);
  /// Clicks the marked line, then follows it every painted frame for `ms`: how far it ever moved,
  /// whether a fold played at some frame, and the card's height at each frame.
  const clickAndWatch = async (page: Page, ms = 450) => {
    const point = await page.evaluate(() => {
      const box = document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect();
      return { x: box.left + Math.min(24, box.width / 2), y: box.top + box.height / 2, top: box.top };
    });
    const watching = page.evaluate(
      ({ duration, from }) =>
        new Promise<{ moved: number; folded: boolean; heights: number[] }>((resolve) => {
          const start = performance.now();
          let moved = 0;
          let folded = false;
          const heights: number[] = [];
          window.cmuxAfterPaint(() => {
            const line = document.querySelector<HTMLElement>("[data-probe]");
            if (line) moved = Math.max(moved, Math.abs(line.getBoundingClientRect().top - from));
            const card = document.querySelector<HTMLElement>('[data-row-id="msg"] .cv-received');
            if (card) heights.push(Math.round(card.getBoundingClientRect().height));
            // The card's own motion, not the chevron's CSS turn.
            const motion = document
              .querySelector('[data-row-id="msg"] .cv-received')
              ?.getAnimations({ subtree: true })
              .filter((animation) => !(animation instanceof CSSTransition));
            if (motion?.length) folded = true;
            if (performance.now() - start < duration) return;
            resolve({ moved, folded, heights });
            return false;
          });
        }),
      { duration: ms, from: point.top },
    );
    await page.mouse.click(point.x, point.y);
    return { ...(await watching), top: point.top };
  };
  const probedTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect().top);
  const expanded = (page: Page) => page.locator("[data-probe]").getAttribute("aria-expanded");
  /// Distinct heights the card was painted at, in order: more than two means it moved by frames.
  const steps = (heights: number[]) => heights.filter((height, index) => height !== heights[index - 1]).length;
  const open = async (reducedMotion: "reduce" | "no-preference") => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };
  const LINE = '[data-row-id="msg"] .cv-disclosure__toggle';
  const DETAILS = '[data-row-id="msg"] .cv-received__more';
  const PANEL = '[data-row-id="msg"] .cv-disclosure__panel';
  /// Puts the message's line `y` px down the view, away from the transcript's end.
  const lineAt = (page: Page, y: number) =>
    page.evaluate((down) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const line = document.querySelector<HTMLElement>('[data-row-id="msg"] .cv-disclosure__toggle')!;
      scroller.scrollTop += line.getBoundingClientRect().top - scroller.getBoundingClientRect().top - down;
    }, y);

  test("the message opened at the latest row stays on its pixel and grows down in a fold", async () => {
    const page = await open("no-preference");
    await show(page, [...done, received]);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    await probe(page, LINE);
    expect(await expanded(page)).toBe("false");
    expect(await page.locator(PANEL).count()).toBe(0);

    const opened = await clickAndWatch(page);
    expect(await expanded(page)).toBe("true");
    expect(opened.folded).toBe(true);
    expect(steps(opened.heights)).toBeGreaterThan(2);
    expect(opened.moved).toBeLessThanOrEqual(1);
    await settle(page);
    expect(Math.abs((await probedTop(page)) - opened.top)).toBeLessThanOrEqual(1);
    // The card opened below the line, past the view's end: the view stopped following.
    expect(await atLatest(page)).toBe(false);
    await page.close();
  });

  test("the message and its Details open and close in place, away from the end", async () => {
    const page = await open("no-preference");
    await show(page, [...done, received, after]);
    await settle(page);
    await lineAt(page, 40);
    await settle(page);
    await probe(page, LINE);

    const opened = await clickAndWatch(page);
    expect(await expanded(page)).toBe("true");
    expect(opened.folded).toBe(true);
    expect(opened.moved).toBeLessThanOrEqual(1);
    await settle(page);
    expect(Math.abs((await probedTop(page)) - opened.top)).toBeLessThanOrEqual(1);

    await probe(page, DETAILS);
    const details = await clickAndWatch(page);
    expect(await expanded(page)).toBe("true");
    expect(details.folded).toBe(true);
    expect(details.moved).toBeLessThanOrEqual(1);
    const detailsShut = await clickAndWatch(page);
    expect(await expanded(page)).toBe("false");
    expect(detailsShut.folded).toBe(true);
    expect(detailsShut.moved).toBeLessThanOrEqual(1);

    await probe(page, LINE);
    const closed = await clickAndWatch(page);
    expect(await expanded(page)).toBe("false");
    expect(closed.folded).toBe(true);
    expect(steps(closed.heights)).toBeGreaterThan(2);
    expect(closed.moved).toBeLessThanOrEqual(1);
    await settle(page);
    expect(Math.abs((await probedTop(page)) - closed.top)).toBeLessThanOrEqual(1);
    expect(await page.locator(PANEL).count()).toBe(0);
    expect(await page.locator(DETAILS).count()).toBe(0);
    await page.close();
  });

  // The name sits before the line's toggle, outside it (Leo, 2026-10-29: "make the left side
  // identifier like it was before and you can click it to go to that session"); this sender is no
  // chat, so the name opens nothing, and the line's toggle opens and closes the message.
  test("the sender's name and the line's toggle never become a gap selection", async () => {
    const page = await open("reduce");
    try {
      await show(page, [...done, received, after]);
      await settle(page);
      await lineAt(page, 100);
      await settle(page);
      const chip = page.locator('[data-row-id="msg"] .cv-received__sender .cv-received__from');
      const toggle = page.locator('[data-row-id="msg"] .cv-disclosure__toggle');
      await chip.evaluate((node) => {
        node.addEventListener("pointerdown", (event) => {
          document.body.dataset.senderPressPrevented = String(event.defaultPrevented);
        });
        document.addEventListener("pointermove", (event) => {
          if (event.buttons === 1) document.body.dataset.senderMovePrevented = String(event.defaultPrevented);
        });
      });
      for (const open of [true, false]) {
        await chip.click({ position: { x: 2, y: 2 } });
        expect(await page.locator('[data-row-id="msg"] .cv-received').getAttribute("data-open")).toBe(
          open ? null : "true",
        );
        await toggle.click({ position: { x: 2, y: 2 } });
        expect(await page.locator('[data-row-id="msg"] .cv-received').getAttribute("data-open")).toBe(
          open ? "true" : null,
        );
        expect(await page.locator("body").getAttribute("data-sender-press-prevented")).toBe("false");
        expect(await page.evaluate(() => window.getSelection()?.toString() ?? "")).toBe("");
      }
      const box = (await chip.boundingBox())!;
      await page.mouse.move(box.x + 2, box.y + 2);
      await page.mouse.down();
      await page.mouse.move(box.x + box.width + 60, box.y + box.height + 50, { steps: 6 });
      expect(await page.locator("body").getAttribute("data-sender-press-prevented")).toBe("false");
      expect(await page.locator("body").getAttribute("data-sender-move-prevented")).toBe("false");
      expect(await page.evaluate(() => window.getSelection()?.toString() ?? "")).toBe("");
    } finally {
      await page.mouse.up();
      await page.close();
    }
  });

  test("under Reduce Motion the message opens and closes at once, and stays on its pixel", async () => {
    const page = await open("reduce");
    await show(page, [...done, received, after]);
    await settle(page);
    await lineAt(page, 200);
    await settle(page);
    await probe(page, LINE);
    const opened = await clickAndWatch(page, 250);
    expect(await expanded(page)).toBe("true");
    expect(opened.folded).toBe(false);
    expect(steps(opened.heights)).toBeLessThanOrEqual(2);
    expect(opened.moved).toBeLessThanOrEqual(1);
    const closed = await clickAndWatch(page, 250);
    expect(await expanded(page)).toBe("false");
    expect(closed.folded).toBe(false);
    expect(steps(closed.heights)).toBeLessThanOrEqual(2);
    expect(closed.moved).toBeLessThanOrEqual(1);
    await page.close();
  });
});
