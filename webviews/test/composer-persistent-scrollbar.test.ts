// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// The composer keeps its scrollbar while its draft overflows (Leo 2026-10-21: "STOP HIDING THEN
// SHOWING THEN HIDING THE SCROLLBAR. IF THERE ARE THINGS TO SCROLL, JUST KEEP THE SCROLLBAR IN THE
// COMPOSER, LIKE CLAUDE DOES."). The prompt (.acpmux-md-field) carries the shared minimal scroller
// (MINIMAL_SCROLLER_ATTRIBUTE, scrollers.ts): a thin thumb on no track, drawn on every frame while
// the draft overflows, through typing, an idle pause, blur, focus and the pointer leaving, and gone
// once the draft fits (its thin lane stays reserved, empty).
//
// Before: the prompt had WebKit's overlay scroller, which shows while the field scrolls and fades
// out a moment later, so it flashed on every line typed; headless engines draw it as a wide classic
// bar or not at all, never the thin one this checks for.
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium (scrollbars on: headless hides them by default) and
// WebKit (the app's engine); CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-persistent-scrollbar.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-persistent-scrollbar.test.ts", async () => {
  setDefaultTimeout(300_000);
  /// The page's frame record (`record`, `recorded`).
  type Recording = Window & { __composerBars?: { bar: number; overflow: number }[]; __stopComposerBars?: () => void };
  const launchers: [string, () => Promise<Browser>][] = [
    ["chromium", () => chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] })],
    ["webkit", () => webkit.launch({ headless: true })],
  ];
  for (const [name, launch] of launchers) {
    try {
      await (await launch()).close();
    } catch {
      throw new Error(`composer-persistent-scrollbar: cannot launch ${name}`);
    }
  }
  const browsers = new Map<string, Browser>();
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, launch] of launchers) browsers.set(name, await launch());
    pane = await papercutPane(() => current!, { turns: 4, running: false });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  const FIELD = ".acpmux-composer-prompt";
  const EDITABLE = ".acpmux-composer-prompt [contenteditable='true']";
  /// The thin scroller's widest lane; WebKit's and Chromium's classic bars are 15 px.
  const THIN = 10;

  const painted = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      for (let left = count; left > 0; left--) await window.cmuxPaintFrame();
    }, count);

  /// Lets `ms` of wall time pass, frames painting all along.
  const idle = (page: Page, ms: number) =>
    // fixed-wait: the behavior is what an idle scroller does over time (an overlay scroller fades
    // out about a second after its last scroll); the frame record runs through the wait.
    page.waitForTimeout(ms);

  /// Records the prompt's scrollbar lane and how far its draft overflows, after every painted frame.
  const record = (page: Page) =>
    page.evaluate((selector) => {
      const bars: { bar: number; overflow: number }[] = [];
      const page = window as Recording;
      page.__composerBars = bars;
      page.__stopComposerBars = window.cmuxAfterPaint(() => {
        const field = document.querySelector<HTMLElement>(selector)!;
        const style = getComputedStyle(field);
        const borders = parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth);
        bars.push({
          bar: Math.round(field.offsetWidth - field.clientWidth - borders),
          overflow: field.scrollHeight - field.clientHeight,
        });
      });
    }, FIELD);
  const recorded = (page: Page) =>
    page.evaluate(() => {
      const page = window as Recording;
      page.__stopComposerBars?.();
      return page.__composerBars ?? [];
    });

  /// Waits for every finite animation on the page (the prompt's growth to fit a paste, the Send
  /// button's and the thread's moves) to finish, then two painted frames, so the probe measures the
  /// box and captures its lane at the same settled place. Mid-growth the prompt's top moves between
  /// the measure and the capture, so the capture's top rows miss the track (Chromium, run
  /// 43363927828). Looping animations (a spinner) never end and never move the prompt.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document.getAnimations().filter((animation) => {
          const end = animation.effect?.getComputedTiming().endTime;
          return animation.playState === "running" && typeof end === "number" && Number.isFinite(end);
        });
      const deadline = performance.now() + 10_000;
      for (let running = finite(); running.length > 0; running = finite()) {
        if (performance.now() > deadline)
          throw new Error(`composer still moving after 10 s: ${running.map((animation) => animation.id || animation.constructor.name).join(", ")}`);
        await Promise.all(running.map((animation) => animation.finished.catch(() => undefined)));
      }
      for (let left = 2; left > 0; left--) await window.cmuxPaintFrame();
    });

  /// Whether the prompt's scrollbar lane shows a thumb as the page draws it: some rows of the lane
  /// differ from the field's padding beside it (a thumb), and some do not (no track). Since #24498
  /// the prompt runs to the box's right edge, so only the lane's rows below the box's rounded top
  /// corner (its rim) and above the mic and Send (where the track stops) can show a thumb.
  async function thumb(page: Page) {
    await settled(page);
    const box = await page.evaluate((selector) => {
      const field = document.querySelector<HTMLElement>(selector)!;
      const rect = field.getBoundingClientRect();
      const style = getComputedStyle(field);
      const borders = parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth);
      const actions = document.querySelector(".acpmux-composer-actions")?.getBoundingClientRect();
      const track = getComputedStyle(field, "::-webkit-scrollbar-track");
      // Codex reserves space after its track before the footer; those empty rows are not track ink.
      const trackBottom = rect.bottom - (parseFloat(track.marginBottom) || 0);
      const bottom = actions && actions.height > 0 ? Math.min(trackBottom, actions.top) : trackBottom;
      // The nearest rounded box around the prompt: its corner's rows are the rim, not the lane.
      let corner = 0;
      for (let node = field.parentElement; node && !corner; node = node.parentElement) {
        const box = node.getBoundingClientRect();
        if (Math.abs(box.right - rect.right) > 2) continue;
        corner = Math.max(0, box.top + parseFloat(getComputedStyle(node).borderTopRightRadius) - rect.top);
      }
      const top = rect.top + Math.ceil(corner);
      return {
        right: rect.right - parseFloat(style.borderRightWidth),
        top,
        height: Math.max(0, bottom - top),
        bar: Math.round(field.offsetWidth - field.clientWidth - borders),
      };
    }, FIELD);
    if (box.bar <= 0 || box.height < 1) return { bar: box.bar, thumb: false, track: false };
    const shot = await page.screenshot({
      clip: { x: box.right - box.bar - 4, y: box.top, width: box.bar + 4, height: Math.floor(box.height) },
    });
    const png = PNG.sync.read(shot);
    const at = (x: number, y: number) => {
      const index = (y * png.width + x) * 4;
      return [png.data[index]!, png.data[index + 1]!, png.data[index + 2]!];
    };
    // Codex's field reaches the glass card edge: its outermost CSS pixel is the card's rim,
    // not the scrollbar track. Keep the lane's interior, at the capture's device scale.
    const end = png.width - Math.ceil(png.width / (box.bar + 4));
    let drawn = 0;
    for (let y = 0; y < png.height; y++) {
      const beside = at(1, y);
      for (let x = 4; x < end; x++) {
        const pixel = at(x, y);
        if (
          Math.abs(pixel[0]! - beside[0]!) + Math.abs(pixel[1]! - beside[1]!) + Math.abs(pixel[2]! - beside[2]!) >
          24
        ) {
          drawn++;
          break;
        }
      }
    }
    const rows: string[] = [];
    for (let y = 0; y < png.height; y++) {
      const beside = at(1, y);
      let hit = false;
      for (let x = 4; x < end; x++) { const pixel = at(x, y); if (Math.abs(pixel[0]! - beside[0]!) + Math.abs(pixel[1]! - beside[1]!) + Math.abs(pixel[2]! - beside[2]!) > 24) { hit = true; break; } }
      rows.push(hit ? "#" : ".");
    }
    const st = await page.evaluate((selector) => { const f = document.querySelector<HTMLElement>(selector)!; return { attr: f.hasAttribute("data-test-opaque-track"), tag: f.tagName, cls: f.className, n: document.querySelectorAll(selector).length, tbg: getComputedStyle(f, "::-webkit-scrollbar-track").backgroundColor, mid: [0,4,6,8,10,11].map((x) => 0) }; }, FIELD);
    console.log("DBG", JSON.stringify({ ...box, st, png: [png.width, png.height], px: [0,2,4,6,8,10,11].map((x) => at(x, Math.floor(png.height / 2)).join("/")), drawn, rows: rows.join("") }));
    return { bar: box.bar, thumb: drawn >= 8, track: drawn > png.height - 8 };
  }

  /// Pastes `lines` long lines into the prompt, as the clipboard would (under 3,500 words and
  /// 20,000 characters, so it lands as text, not a Pasted text chip, pastedText.ts).
  async function paste(page: Page, lines: number) {
    await page.locator(EDITABLE).click();
    await page.evaluate(
      ({ selector, count }) => {
        const data = new DataTransfer();
        const lines = Array.from(
          { length: count },
          (_, i) => `draft line ${i + 1}: keep the retry rules and the tests in sync with the docs, and say why.`,
        );
        data.setData("text/plain", lines.join("\n"));
        document
          .querySelector(selector)!
          .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      },
      { selector: EDITABLE, count: lines },
    );
    await page.waitForFunction(({ selector, last }) => document.querySelector(selector)?.textContent?.includes(last), {
      selector: EDITABLE,
      last: `draft line ${lines}:`,
    });
    await painted(page, 3);
  }

  for (const [name] of launchers) {
    describe(name, () => {
      test("the thumb probe ignores the card rim and rejects an opaque track in both looks", async () => {
        current = browsers.get(name);
        for (const look of ["codex", "claude"]) {
          const page = await pane!.open(undefined, async (page) => {
            await page.addInitScript((look) => localStorage.setItem("cmux.composer.look", look), look);
          });
          try {
            await paste(page, 20);
            const normal = await thumb(page);
            expect(normal).toEqual({ bar: normal.bar, thumb: true, track: false });
            // Keyed on an attribute of the prompt itself: WebKit restyles a custom scrollbar only when
            // its element's own style changes, so a new sheet alone leaves the old, clear track
            // painted (webkit failed this every run on Linux). Setting the attribute is how the
            // product changes the lane too (scrollers.ts SETTLING_SCROLLER_ATTRIBUTE).
            await page.addStyleTag({
              content:
                ":root .acpmux-composer-prompt[data-test-opaque-track]::-webkit-scrollbar-track { background: rgb(255, 0, 255) !important; }",
            });
            await page.evaluate((selector) => document.querySelector(selector)!.setAttribute("data-test-opaque-track", ""), FIELD);
            await painted(page, 3);
            const opaque = await thumb(page);
            expect(opaque).toEqual({ bar: opaque.bar, thumb: true, track: true });
          } finally {
            await page.close();
          }
        }
      });

      // With the agent pane's scrollbar fade on too (its default, `data-cmux-scroller-fade`): it fades
      // the transcript's thumb at rest, never the composer's (Leo 2026-10-21, ask-c8936f0e52).
      for (const fade of [false, true])
        test(`an overflowing draft keeps a thin thumb on every frame, through typing, idle, blur, focus and pointer leave${fade ? ", under the scrollbar fade" : ""}`, async () => {
          current = browsers.get(name);
          const page = await pane!.open();
          await page.evaluate((on) => document.documentElement.toggleAttribute("data-cmux-scroller-fade", on), fade);
          await paste(page, 20);

          const seen: Record<string, Awaited<ReturnType<typeof thumb>>> = {};
          await record(page);
          // Typing at the end of the draft.
          await page.keyboard.type(" and one more thing", { delay: 25 });
          await painted(page, 3);
          seen.typed = await thumb(page);
          // An idle pause past any overlay fade (AppKit's starts under a second).
          for (const at of [500, 1000, 1500, 2000, 2500]) {
            await idle(page, 500);
            seen[`idle ${at}ms`] = await thumb(page);
          }
          // Focus leaves the prompt.
          await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
          await painted(page, 3);
          await idle(page, 1200);
          seen.blurred = await thumb(page);
          // Focus comes back.
          await page.locator(EDITABLE).focus();
          await painted(page, 3);
          await idle(page, 1200);
          seen.focused = await thumb(page);
          // The pointer crosses the prompt and leaves it.
          const box = (await page.locator(FIELD).boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await painted(page, 3);
          await page.mouse.move(4, 4);
          await painted(page, 3);
          await idle(page, 1200);
          seen.left = await thumb(page);
          const frames = await recorded(page);

          console.log(
            `${name}: ${frames.length} frames, lane widths ${[...new Set(frames.map((frame) => frame.bar))].join(",")}`,
          );
          expect(frames.length).toBeGreaterThan(30);
          // Every frame: the draft overflows, and the lane is there and thin.
          const bad = frames.filter((frame) => !(frame.overflow > 0 && frame.bar > 0 && frame.bar <= THIN));
          expect({ badFrames: bad.length, first: JSON.stringify(bad[0] ?? null) }).toEqual({
            badFrames: 0,
            first: "null",
          });
          // Every sample: a thumb is drawn, on no track.
          for (const [phase, sample] of Object.entries(seen))
            expect({ phase, ...sample }).toEqual({ phase, bar: sample.bar, thumb: true, track: false });

          // Cut back to a draft that fits: no thumb on any frame. The thin lane stays reserved and
          // empty (overflow-y: scroll), so the draft never rewraps as it starts or stops overflowing.
          await page.locator(EDITABLE).click();
          await page.keyboard.press("ControlOrMeta+A");
          await page.keyboard.type("short again");
          await painted(page, 3);
          await record(page);
          await painted(page, 20);
          await idle(page, 1200);
          const fits = await recorded(page);
          expect(fits.length).toBeGreaterThan(10);
          expect(fits.filter((frame) => frame.overflow > 0 || frame.bar > THIN)).toEqual([]);
          const fitted = await thumb(page);
          expect(fitted).toEqual({ bar: fitted.bar, thumb: false, track: false });
          await page.close();
        });
    });
  }
});
