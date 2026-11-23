// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts, not shipped UI.
// Where a send from the composer lands (ask-9edf643c4d, 2026-11-22: sends from the composer jumped the
// transcript somewhere). A sent prompt goes to the top of the view, the same place every time, from the
// latest row or scrolled up, whatever its length (VirtualTranscript.tsx `SendTopHold`). Scrolled up, a 15
// or 30 line send landed its prompt 97 px under the top where a send from the latest row lands it 44 px.
//
// Each case: the pane's production build (papercutChat.ts, a stand-in acpmux, 40 finished turns), a pane
// 360 px or 1280 px wide and 800 px tall, at the latest row or scrolled up, a prompt of 1, 5, 30 or 300
// lines with a blank line between each, with or without a pasted image. Once the send settles (its turn
// still running), the sent prompt's row top under the transcript's top is its landing: every case of a
// width lands where a one-line send from the latest row does; one too tall for that (a tall image) follows its
// turn's live line, above the composer.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("agent-pane-send-lands-browser.test.ts", async () => {
  setDefaultTimeout(900_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-lands-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("a send lands at one place", () => test("chromium", () => {}));
    return;
  }
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 40,
      running: false,
      production: {},
    });
  });
  afterAll(async () => {
    for (const page of pages.values()) await page.close();
    await pane?.close();
    await browser?.close();
  });

  const HEIGHT = 800;

  /// Until the transcript, the dock and every finite animation hold still over 12 painted frames (at most 900).
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let last = "";
          let still = 0;
          let count = 0;
          window.cmuxAfterPaint(() => {
            count += 1;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            const box = document.querySelector<HTMLElement>(".acpmux-composer-box");
            const now = [scroller?.scrollTop, scroller?.scrollHeight, box?.getBoundingClientRect().height].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" &&
                  Number.isFinite(animation.effect?.getComputedTiming().endTime ?? Number.POSITIVE_INFINITY),
              );
            still = now === last && !running ? still + 1 : 0;
            last = now;
            if (still < 12 && count < 900) return true;
            resolve();
            return false;
          });
        }),
    );
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
    });
  /// The sent prompt's row top under the transcript's top, and whether it and the rows after it (the
  /// turn's live line) fit over the composer's stack with the prompt at `home`.
  const landing = (page: Page, tag: string, home: number | null) =>
    page.evaluate(
      ({ tag, home }) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const rows = [...document.querySelectorAll(".acpmux-thread > .acpmux-row")];
        const row = rows.find(
          (node) => node.classList.contains("acpmux-user") && node.textContent?.includes(`${tag} line 1:`),
        );
        if (!row) return { top: null, fits: true, lastAboveDock: false };
        const top = row.getBoundingClientRect().top;
        const last = rows.at(-1)!.getBoundingClientRect().bottom;
        const dock = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().top;
        return {
          top: Math.round(top - scroller.top),
          fits: home === null || last - top <= dock - scroller.top - home,
          lastAboveDock: last <= dock + 1,
        };
      },
      { tag, home },
    );

  const paste = (page: Page, what: { text: string } | { image: true }) =>
    page.evaluate(
      async ({ what, prompt }) => {
        const data = new DataTransfer();
        if ("text" in what) data.setData("text/plain", what.text);
        else {
          const canvas = document.createElement("canvas");
          canvas.width = 640;
          canvas.height = 400;
          const context = canvas.getContext("2d")!;
          context.fillStyle = "#1b1c20";
          context.fillRect(0, 0, 640, 400);
          const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
          data.items.add(new File([blob], "shot.png", { type: "image/png" }));
        }
        const field = document.querySelector(prompt)!;
        const event = new ClipboardEvent("paste", {
          clipboardData: data,
          bubbles: true,
          cancelable: true,
        });
        if (event.clipboardData !== data) Object.defineProperty(event, "clipboardData", { value: data });
        field.dispatchEvent(event);
      },
      { what, prompt: COMPOSER_EDITOR },
    );

  type Case = {
    lines: number;
    image: boolean;
    where: "bottom" | "up";
    width: number;
  };
  const key = (c: Case) => `${c.width}px ${c.where} ${c.lines} lines${c.image ? " +image" : ""}`;

  const pages = new Map<number, Page>();
  async function pageFor(width: number): Promise<Page> {
    const kept = pages.get(width);
    if (kept) return kept;
    const page = await browser.newPage({ viewport: { width, height: HEIGHT } });
    await installPaintedFrames(page);
    await page.goto(pane.address());
    await page.locator(COMPOSER_EDITOR).first().waitFor({ timeout: 120_000 });
    await page.locator(".acpmux-thread > .acpmux-row").first().waitFor({ timeout: 120_000 });
    await settle(page);
    pages.set(width, page);
    return page;
  }

  let sent = 0;
  async function play(c: Case, home: number | null) {
    const page = await pageFor(c.width);
    await page.keyboard.press("Escape");
    if ((await fromEnd(page)) > 1) {
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = scroller.scrollHeight;
      });
      await settle(page);
    }
    if (c.where === "up") {
      await page.mouse.move(c.width / 2, 200);
      for (let moved = 0; moved < 1200; moved += 40) await page.mouse.wheel(0, -40);
      await settle(page);
    }
    const tag = `Send ${(sent += 1)}`;
    const lines = Array.from({ length: c.lines }, (_, i) => `${tag} line ${i + 1}: the relay and its retry path`);
    await page.locator(COMPOSER_EDITOR).first().click();
    if (c.lines <= 5) {
      for (const [i, line] of lines.entries()) {
        if (i) {
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.press("Shift+Enter");
        }
        await page.keyboard.type(line);
      }
    } else await paste(page, { text: lines.join("\n\n") });
    if (c.image) {
      await paste(page, { image: true });
      await page.waitForFunction(() => {
        const box = document.querySelector(".acpmux-composer-box")!;
        return (
          !box.querySelector('[aria-busy="true"]') && box.querySelector(".acpmux-md-inline-chip, .acpmux-attachment")
        );
      });
    }
    await settle(page);
    const upPx = Math.round(await fromEnd(page));
    const asked = pane.sent("session/prompt", pane.methods.filter((method) => method === "session/prompt").length);
    const before = pane.prompts.length;
    await page.keyboard.press("Enter");
    await asked;
    const promptId = pane.prompts[before]?._meta?.acpmux?.promptId as string;
    pane.record("user_message", {
      text: lines.join("\n\n"),
      promptId,
      turnId: `turn-${promptId}`,
    });
    pane.record("turn_started", {});
    await settle(page);
    const landed = await landing(page, tag, home);
    pane.record("turn_result", { status: "completed" });
    await settle(page);
    return { landed, upPx };
  }

  for (const width of [360, 1280])
    describe(`${width} px`, () => {
      // Where a one-line send from the latest row lands: every other case of the width lands there.
      let home: number | null = null;
      const cases: Case[] = [{ lines: 1, image: false, where: "bottom", width }];
      for (const where of ["bottom", "up"] as const)
        for (const lines of [1, 5, 15, 30, 300])
          for (const image of [false, true])
            if (where !== "bottom" || lines !== 1 || image) cases.push({ lines, image, where, width });
      for (const c of cases)
        test(key(c), async () => {
          const { landed, upPx } = await play(c, home);
          home ??= landed.top;
          console.log(
            `send-lands ${JSON.stringify({ case: key(c), landed: landed.top, home, fits: landed.fits, scrolledUpPx: upPx })}`,
          );
          expect(landed.top).not.toBeNull();
          // A prompt taller than the view over the stack (a tall image) cannot rest at the top with its
          // turn's live line in sight: the view follows that line instead (`SendTopHold`, outgrown).
          if (!landed.fits)
            expect({
              case: key(c),
              lastAboveDock: landed.lastAboveDock,
            }).toEqual({ case: key(c), lastAboveDock: true });
          else
            expect({ case: key(c), landed: landed.top }).toEqual({
              case: key(c),
              landed: home,
            });
        });
    });
});
