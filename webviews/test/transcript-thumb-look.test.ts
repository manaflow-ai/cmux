// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The transcript's scrollbar thumb while the reader scrolls up a long chat whose older pages load in,
// then reaches for the shown thumb and lets it go, then hovers its bar at rest (no thumb: hover alone
// never shows one, Leo 2026-11-22) (Leo, 2026-11-20, in his NIGHTLY: "you know, when i scroll
// up, the infinite scroll for some reason actually seems to be kinda good? ... the thumb needs to look
// better when i do stuff"). Every painted frame is read, and the run fails when the thumb:
//
// - pops in or out: its drawn ink goes from one resting ink (none, 38, 55) to another in one frame,
//   with no step between drawn (a slow frame may land mid-fade far along; a pop lands nowhere between).
//   Before, the pointer coming near the bar (scrollers.ts NEAR_ATTRIBUTE) drew it at 55% in
//   one frame from nothing at rest, and leaving took it back to nothing in one frame, as hovering
//   the thumb did (Leo, 2026-10-29: "the scroll thumb should fade instead of disappearing instantly").
// - snaps wider or thinner: its border (the thumb's width is the lane less twice that) goes from 2 px
//   to the near border, or back, in one frame.
// - jumps while pages land: its top moves down while the reader goes up, or its height changes by
//   more than a pixel in a frame (the room held above the loaded rows, conversation/olderReserve.ts).
//
// The page is the pane's dev entry talking to a stand-in acpmux (support/papercutChat.ts) holding the
// generated ordinary chat (bench/godFixture.ts), each older page answered PAGE_LATENCY_MS late, under
// the agent pane's scrollbar fade (paneTheme.ts sets SCROLLER_FADE_ATTRIBUTE, as the host does). Real
// wheel and pointer input from Playwright. SCREENCAST_DIR (Chromium) keeps every painted frame as a
// JPEG, for a PR's before and after video.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { godLog } from "../bench/godFixture";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-thumb-look.test.ts", async () => {
  setDefaultTimeout(420_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["webkit", webkit],
    ["chromium", chromium],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`transcript-thumb-look: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("transcript thumb look", () => test("no engine", () => {}));
    return;
  }

  const TURNS = 600;
  const PAGE_LATENCY_MS = 900;
  /// The inks a thumb rests at (none under the fade, while it scrolls, near the pointer) and the
  /// borders (scrolling, near); a frame that goes from one to another with nothing between is a pop.
  const RESTING_INKS = [0, 38, 55];
  const RESTING_BORDERS = [2, 1];
  const resting = (value: number, values: number[]) => values.some((each) => Math.abs(value - each) < 0.5);
  const pop = (from: number, to: number, values: number[]) =>
    Math.abs(to - from) > 0.5 && resting(from, values) && resting(to, values);

  const log = godLog("small", { turns: TURNS, imageEvery: 25, chainEvery: 150 });
  const lead: PapercutStep[] = log.events.map((event) => [
    event.dir,
    event.kind,
    event.msg as Record<string, unknown>,
    event.at,
  ]);
  const prompts = log.events.filter((event) => event.kind === "user_message").length + 1;

  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  type Frame = {
    phase: string;
    ink: number;
    border: number;
    near: boolean;
    scrolling: boolean;
    thumbTop: number;
    thumbHeight: number;
    rows: number;
  };

  for (const [name] of engines)
    test(`${name}: the thumb fades in, out and wide, and holds still while older pages land`, async () => {
      const pane = await papercutPane(() => browsers.get(name)!, {
        turns: 1,
        running: false,
        lead,
        attachPage: 160,
        session: { turnCount: prompts },
        eventsLatencyMs: PAGE_LATENCY_MS,
        daemonIndexes: true,
      });
      try {
        const page = await pane.open({ width: 1100, height: 800 });
        await page.evaluate(() => document.documentElement.setAttribute("data-cmux-scroller-fade", ""));
        const view = (await page.locator(".acpmux-scroll").boundingBox())!;
        const middle = { x: view.x + view.width / 2, y: view.y + view.height / 2 };
        await page.mouse.move(middle.x, middle.y);
        await page.waitForFunction(
          () => Number(document.querySelector("[data-older-room]")?.getAttribute("data-older-room")) > 0,
          null,
          { timeout: 60_000 },
        );
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const frames: Omit<Frame, "phase">[] = [];
          const phases: string[] = [];
          const watch = window as unknown as { __thumb: { frames: typeof frames; phases: string[]; phase: string } };
          watch.__thumb = { frames, phases, phase: "start" };
          // The ink and border the thumb is drawn with, as SCROLLER_ROOT_CSS resolves them: a near
          // scroller under the old rules drew its own colour and border, whatever the ink.
          window.cmuxAfterPaint(() => {
            const style = getComputedStyle(scroller);
            const near = scroller.hasAttribute("data-cmux-scroller-near");
            const share = style.getPropertyValue("--cmux-shown-scroller-near").trim();
            const legacyNear = near && !share;
            const ink = legacyNear ? 55 : Number.parseFloat(style.getPropertyValue("--cmux-shown-scroller-ink")) || 0;
            const nearBorder =
              Number.parseFloat(
                style.getPropertyValue("--cmux-shown-scroller-near-border") ||
                  style.getPropertyValue("--cmux-scroller-near-border"),
              ) || 1;
            const border = legacyNear ? nearBorder : 2 - (2 - nearBorder) * (Number.parseFloat(share) || 0);
            const lane = scroller.clientHeight;
            frames.push({
              ink,
              border,
              near,
              scrolling: scroller.hasAttribute("data-cmux-scrolling"),
              thumbTop: (scroller.scrollTop / scroller.scrollHeight) * lane,
              thumbHeight: Math.max(24, (lane / scroller.scrollHeight) * lane),
              rows: scroller.querySelectorAll(".acpmux-row").length,
            });
            phases.push(watch.__thumb.phase);
          });
        });
        const phase = (value: string) =>
          page.evaluate((value) => {
            (window as unknown as { __thumb: { phase: string } }).__thumb.phase = value;
          }, value);
        const castDir = name === "chromium" ? process.env.SCREENCAST_DIR : undefined;
        const cast = castDir ? await page.context().newCDPSession(page) : undefined;
        let castFrames = 0;
        if (cast && castDir) {
          fs.mkdirSync(castDir, { recursive: true });
          cast.on("Page.screencastFrame", (frame: { data: string; sessionId: number }) => {
            castFrames += 1;
            fs.writeFileSync(
              path.join(castDir, `f${String(castFrames).padStart(5, "0")}.jpg`),
              Buffer.from(frame.data, "base64"),
            );
            void cast.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
          });
          await cast.send("Page.startScreencast", { format: "jpeg", quality: 80, everyNthFrame: 1 });
        }
        /// Until the thumb rests: not scrolling, near the pointer or not as asked, and no fade's
        /// inline ink left (followShownScrollerFade clears it when a fade ends).
        const settled = (near: boolean) =>
          page.waitForFunction(
            (near) => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              return (
                !scroller.hasAttribute("data-cmux-scrolling") &&
                scroller.hasAttribute("data-cmux-scroller-near") === near &&
                !scroller.style.getPropertyValue("--cmux-shown-scroller-ink")
              );
            },
            near,
            { timeout: 10_000 },
          );
        const pagesBefore = pane.methods.filter((method) => method === "_acpmux/events").length;
        for (let round = 0; round < 3; round++) {
          // Up through the history, a quick trackpad scroll, while pages land above.
          await phase(`wheel-${round}`);
          for (let step = 0; step < 90; step++) {
            await page.mouse.wheel(0, -[80, 190, 120, 256, 145, 202][step % 6]!);
            // fixed-wait: the gap between wheel events is the input itself, a trackpad's cadence.
            await page.waitForTimeout(16);
          }
          // Reaching for the thumb while it shows from the scroll: it widens, and holds once the
          // scroll stops while the pointer stays on its bar; then out as the pointer leaves.
          await phase(`near-${round}`);
          await page.mouse.move(view.x + view.width - 4, middle.y, { steps: 6 });
          // The screencast can make the move outlast the linger; a step of scroll back down (the view is at the top by now) with the pointer
          // on the bar shows the thumb again, and the pointer there holds it.
          await page.evaluate(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const seen: string[] = ((window as any).__marks = []);
            new MutationObserver((records) => {
              for (const record of records)
                seen.push(
                  `${record.attributeName}=${scroller.hasAttribute(record.attributeName!)}@${Math.round(performance.now())}`,
                );
            }).observe(scroller, {
              attributes: true,
              attributeFilter: ["data-cmux-scrolling", "data-cmux-scroller-near"],
            });
          });
          await page.evaluate(
            ([x, y]) => {
              const seen = (window as any).__marks as string[];
              const name = (node: Element | null) =>
                node ? `${node.tagName.toLowerCase()}.${String(node.className).slice(0, 60)}` : "none";
              const chain = (node: Element | null) => {
                const out: string[] = [];
                for (let at = node; at && out.length < 6; at = at.parentElement) out.push(name(at));
                return out.join(" < ");
              };
              seen.push(`at point: ${chain(document.elementFromPoint(x, y))}`);
              window.addEventListener(
                "wheel",
                (event) => {
                  const target = event.target as Element;
                  seen.push(`wheel target=${chain(target)} cancelable=${event.cancelable}`);
                  setTimeout(() => seen.push(`wheel after: prevented=${event.defaultPrevented}`));
                },
                { capture: true, passive: true },
              );
              for (const type of ["pointerleave", "blur", "pointermove"])
                window.addEventListener(
                  type,
                  (event) =>
                    seen.push(
                      `${type} buttons=${(event as PointerEvent).buttons ?? ""} @${Math.round(performance.now())}`,
                    ),
                  { capture: true, passive: true },
                );
              document.addEventListener("scroll", () => seen.push("scroll"), {
                capture: true,
                passive: true,
                once: true,
              });
            },
            [view.x + view.width - 4, middle.y + 1],
          );
          // A move on the bar while the scroll shows reads the pointer against the shown thumb.
          await page.mouse.move(view.x + view.width - 4, middle.y + 1, { steps: 2 });
          await page.mouse.wheel(0, 60);
          await settled(true).catch(async (error) => {
            const state = await page.evaluate(() => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              return {
                attributes: scroller.getAttributeNames().filter((name) => name.startsWith("data-cmux")),
                marks: (window as any).__marks,
                now: Math.round(performance.now()),
                lane: scroller.offsetWidth - scroller.clientWidth,
                rectRight: scroller.getBoundingClientRect().right,
                scrollingNow: scroller.hasAttribute("data-cmux-scrolling"),
                top: scroller.scrollTop,
                height: scroller.scrollHeight,
                client: scroller.clientHeight,
                ink: scroller.style.getPropertyValue("--cmux-shown-scroller-ink"),
              };
            });
            throw new Error(`round ${round} never settled near: ${JSON.stringify(state)}`, { cause: error });
          });
          await phase(`leave-${round}`);
          await page.mouse.move(middle.x, middle.y, { steps: 6 });
          await settled(false);
          // At rest, the pointer on the bar alone shows nothing (Leo 2026-11-22: "hovering only
          // doesnt show").
          await phase(`rest-${round}`);
          await page.mouse.move(view.x + view.width - 4, middle.y, { steps: 6 });
          for (let frame = 0; frame < 6; frame++) await page.evaluate(() => new Promise(requestAnimationFrame));
          await settled(false);
          await page.mouse.move(middle.x, middle.y, { steps: 6 });
        }
        if (cast) await cast.send("Page.stopScreencast").catch(() => {});
        const { frames, phases } = await page.evaluate(
          () => (window as unknown as { __thumb: { frames: Omit<Frame, "phase">[]; phases: string[] } }).__thumb,
        );
        const read: Frame[] = frames.map((frame, index) => ({ ...frame, phase: phases[index]! }));
        const pages = pane.methods.filter((method) => method === "_acpmux/events").length - pagesBefore;

        let inkPops = 0;
        let inkPopMax = 0;
        let borderSnaps = 0;
        let thumbDown = 0;
        let thumbResizes = 0;
        let thumbResizeMax = 0;
        const firstPops: string[] = [];
        for (let index = 1; index < read.length; index++) {
          const before = read[index - 1]!;
          const frame = read[index]!;
          if (pop(before.ink, frame.ink, RESTING_INKS)) {
            inkPops += 1;
            inkPopMax = Math.max(inkPopMax, Math.abs(frame.ink - before.ink));
            if (firstPops.length < 8)
              firstPops.push(
                `${frame.phase}: ink ${before.ink.toFixed(0)}->${frame.ink.toFixed(0)}, near ${frame.near}`,
              );
          }
          if (pop(before.border, frame.border, RESTING_BORDERS)) borderSnaps += 1;
          if (frame.phase.startsWith("wheel")) {
            if (frame.thumbTop - before.thumbTop > 1) thumbDown += 1;
            const resize = Math.abs(frame.thumbHeight - before.thumbHeight);
            if (resize > 1) {
              thumbResizes += 1;
              thumbResizeMax = Math.max(thumbResizeMax, resize);
            }
          }
        }
        const summary = {
          pages,
          frames: read.length,
          nearFrames: read.filter((frame) => frame.near).length,
          inkPops,
          inkPopMax: Math.round(inkPopMax),
          borderSnaps,
          thumbDown,
          thumbResizes,
          thumbResizeMax: Math.round(thumbResizeMax * 100) / 100,
          firstPops,
        };
        console.log(`transcript-thumb-look ${name}: ${JSON.stringify(summary)}`);
        expect(pages).toBeGreaterThanOrEqual(2);
        expect(summary.nearFrames).toBeGreaterThan(0);
        expect(summary.inkPops).toBe(0);
        expect(summary.borderSnaps).toBe(0);
        expect(summary.thumbDown).toBe(0);
        expect(summary.thumbResizes).toBe(0);
      } finally {
        await pane.close();
      }
    });
});
