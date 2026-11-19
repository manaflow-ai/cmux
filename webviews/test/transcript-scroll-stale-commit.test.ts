// l10n-allow-file: the harness's synthetic rows, not shipped UI.
// The transcript's scroll offset lives outside React (VirtualTranscript.tsx `scrollRef`), and a scroll
// frame renders only when its row window moves (`commitScroll`). Two things a frame that renders
// nothing must still do:
// - A render that yields (the warm rows' transition) reads the offset once. A frame that comes while it
//   waits reads its own offset against the commit before, matches it, and paints only the soft edges.
//   The transition's commit must not then paint the edges of the offset it read: scrolled to the very
//   top, `data-fade-top` stayed on.
// - A pointer held on the scroller that pushed into the room above the loaded rows notes a target there
//   (conversation/olderScrollTarget.ts). While it is held, every frame puts the reader back at the
//   room's edge; a frame that renders nothing did not, and the reader moved off it until a page landed.
//
// The transition's yield is made exact rather than waited for: React hands its hooks dispatcher to the
// DevTools hook, and the test wraps `useDeferredValue` so that TranscriptView's call with its warm rows'
// place (a string of three lines, scrollWindow.ts warmAnchor), in a render outside an animation frame,
// moves the offset to 0 and runs the transcript's scroll frame there (the motion clock's scroll event,
// which commits in place). That is a frame arriving after the render read the offset and before it
// commits. The commit's soft edges are read in the DevTools hook's commit callback, after its layout
// effects and before anything later can repaint them.
//
// Real Chromium and WebKit (transcript-older-scroll.harness.tsx: `?all` holds 3000 rows with nothing to
// page; `?prompts` holds room above a tail whose pages never land here). CI fails the file when an
// engine cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type StaleWindow = Window & {
  __stale?: {
    armed: boolean;
    /// TranscriptView renders that moved the offset (outside a frame), and its warm rows' place then.
    fired: number;
    firedWith?: string;
    /// Matching renders seen inside an animation frame while armed (an urgent render, not the transition).
    inFrame: number;
    /// The first commit after the move: the scroller's offset and soft edge as that commit left them.
    atCommit?: { top: number; fadeTop: boolean; topReach: string };
    pending: boolean;
    /// The transcript's motion-scroll listener was found and run.
    transcriptListener?: boolean;
  };
};

await requireBrowserLane("transcript-scroll-stale-commit.test.ts", async () => {
  /// Before the page's own code: a DevTools hook React injects its internals into, `requestAnimationFrame`
  /// marked so a render can tell a frame's commit from a task's, and the hooks dispatcher's
  /// `useDeferredValue` wrapped (see the file comment).
  function installStaleCommitProbe() {
    const state = { armed: false, fired: 0, inFrame: 0, pending: false } as NonNullable<StaleWindow["__stale"]>;
    (window as StaleWindow).__stale = state;
    let inFrame = 0;
    const raf = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = (callback: FrameRequestCallback) =>
      raf((time) => {
        inFrame += 1;
        try {
          callback(time);
        } finally {
          inFrame -= 1;
        }
      });
    const scroller = () => document.querySelector<HTMLElement>(".acpmux-scroll");
    let stopSwallow = () => {};
    const deferred = (value: unknown) => {
      if (!state.armed || typeof value !== "string" || value.split("\n").length !== 3) return;
      if (inFrame > 0) {
        state.inFrame += 1;
        return;
      }
      const node = scroller();
      if (!node) return;
      state.armed = false;
      state.fired += 1;
      state.firedWith = value;
      state.pending = true;
      node.scrollTop = 0;
      // That write's own scroll event comes with the next frame. Should the render yield to one first,
      // the event would reach the minimap's listener, whose flushSync update interrupts the transition
      // and renders it again from the new offset (WebKit, some runs). The transcript has read the offset
      // already (below), so the event says nothing new: it is held from every listener until the commit.
      const swallow = (event: Event) => {
        if (event.target === node && state.pending) event.stopImmediatePropagation();
      };
      window.addEventListener("scroll", swallow, true);
      stopSwallow = () => window.removeEventListener("scroll", swallow, true);
      // The transcript's listener for the motion clock's scroll event (threadMinimap/scrollMotion.ts
      // MOTION_SCROLL_EVENT) reads the offset and runs its scroll frame at once. Called alone: the
      // event itself also reaches the minimap, whose own flushSync update during the render made React
      // render the transition again, from the new offset, on some runs and not others.
      const transcriptMoved = motionListeners.find((each) => each.node === node && each.transcript);
      transcriptMoved?.listener.call(node, new Event("acpmux-motion-scroll"));
      state.transcriptListener = transcriptMoved !== undefined;
    };
    /// Who listens for the motion clock's scroll event, and whether VirtualTranscript.tsx added it.
    const motionListeners: { node: EventTarget; listener: EventListener; transcript: boolean }[] = [];
    const addEventListener = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function (
      this: EventTarget,
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: boolean | AddEventListenerOptions,
    ) {
      if (type === "acpmux-motion-scroll" && typeof listener === "function")
        motionListeners.push({
          node: this,
          listener,
          transcript: (new Error().stack ?? "").includes("VirtualTranscript.tsx"),
        });
      return addEventListener.call(this, type, listener, options);
    };
    const wrapped = new WeakSet<object>();
    const wrap = (dispatcher: any) => {
      if (!dispatcher || typeof dispatcher.useDeferredValue !== "function" || wrapped.has(dispatcher))
        return dispatcher;
      wrapped.add(dispatcher);
      const original = dispatcher.useDeferredValue;
      dispatcher.useDeferredValue = function (value: unknown, initial?: unknown) {
        deferred(value);
        return original.call(this, value, initial);
      };
      return dispatcher;
    };
    const hook = {
      renderers: new Map<number, unknown>(),
      supportsFiber: true,
      inject(renderer: { currentDispatcherRef?: Record<string, unknown> }) {
        const internals = renderer.currentDispatcherRef;
        if (internals) {
          let current = wrap(internals.H);
          Object.defineProperty(internals, "H", {
            configurable: true,
            get: () => current,
            set: (value) => {
              current = wrap(value);
            },
          });
        }
        const id = hook.renderers.size + 1;
        hook.renderers.set(id, renderer);
        return id;
      },
      onCommitFiberRoot() {
        if (!state.pending) return;
        const node = scroller();
        if (!node) return;
        state.pending = false;
        stopSwallow();
        state.atCommit = {
          top: node.scrollTop,
          fadeTop: node.hasAttribute("data-fade-top"),
          topReach: node.style.getPropertyValue("--acpmux-fade-top-reach"),
        };
      },
      onScheduleFiberRoot() {},
      onCommitFiberUnmount() {},
      onPostCommitFiberRoot() {},
      checkDCE() {},
    };
    (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ = hook;
  }

  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const harness = "/test/browser/transcript-older-scroll.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, harness);
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  async function open(browser: Browser, query: string, probe: boolean): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    if (probe) await page.addInitScript(installStaleCommitProbe);
    await page.goto(`${base}${harness}?${query}`);
    await page.waitForFunction(
      () => document.querySelectorAll(".acpmux-scroll .acpmux-row[data-row-id]").length > 0,
      null,
      { timeout: 60_000 },
    );
    return page;
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`transcript-scroll-stale-commit (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a transition that read the offset before a frame moved it to the top commits no top soft edge", async () => {
        const page = await open(browser!, "all", true);
        const run = await page.evaluate(async () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const state = (window as StaleWindow).__stale!;
          // raf-read: it reads the offset and the mounted row ids, which the scroll and React set before the frame.
          const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
          const key = () =>
            [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")]
              .map((row) => row.dataset.rowId)
              .join(",");
          /// The same mounted rows and offset for 30 frames in a row: the scroll's lead has decayed and
          /// the deferred warm rows have landed.
          const settle = async () => {
            let still = 0;
            let last = "";
            let lastTop = -1;
            for (let frames = 0; still < 30 && frames < 1200; frames += 1) {
              await frame();
              const now = key();
              still = now === last && scroller.scrollTop === lastTop ? still + 1 : 0;
              last = now;
              lastTop = scroller.scrollTop;
            }
            return still;
          };
          const moveTo = async (top: number) => {
            await frame();
            scroller.dispatchEvent(
              new WheelEvent("wheel", { deltaY: top - scroller.scrollTop, bubbles: true, cancelable: true }),
            );
            scroller.scrollTop = top;
            return settle();
          };
          // Parked 20 px from the top: the warm rows are built from the first row.
          let still = await moveTo(20);
          if (Math.abs(scroller.scrollTop - 20) > 1) still = await moveTo(20);
          const parked = { still, top: scroller.scrollTop, height: scroller.clientHeight };
          // One frame down by 0.3 of a viewport: the warm rows' place moves a step (half a viewport) and
          // the mounted rows do not, so the frame starts a transition and renders nothing itself.
          state.armed = true;
          const to = Math.round(scroller.clientHeight * 0.3);
          await frame();
          scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: to - 20, bubbles: true, cancelable: true }));
          scroller.scrollTop = to;
          for (let frames = 0; frames < 600 && (state.fired === 0 || state.pending); frames += 1) await frame();
          state.armed = false;
          const settled = await settle();
          return {
            parked,
            to,
            fired: state.fired,
            firedWith: state.firedWith?.replaceAll("\n", "|"),
            inFrame: state.inFrame,
            transcriptListener: state.transcriptListener,
            atCommit: state.atCommit,
            settled,
            after: {
              top: scroller.scrollTop,
              fadeTop: scroller.hasAttribute("data-fade-top"),
              topReach: scroller.style.getPropertyValue("--acpmux-fade-top-reach"),
            },
          };
        });
        await page.close();
        console.log(`STALE-COMMIT ${JSON.stringify({ engine: name, case: "fade", ...run })}`);
        expect(run.parked.still, "the parked transcript held still").toBe(30);
        expect(run.parked.top).toBeLessThanOrEqual(21);
        // The setup is what it says: the move rendered nothing in its frame, and the transition that
        // read it moved the offset to the top once.
        expect(run.inFrame, "urgent renders of the move").toBe(0);
        expect(run.fired, "transition renders that moved the offset").toBe(1);
        expect(run.transcriptListener, "the transcript's scroll frame ran").toBe(true);
        expect(run.atCommit?.top).toBe(0);
        // That transition's commit drew the soft edges of the offset now, the top: none at the top.
        expect(
          { fadeTop: run.atCommit?.fadeTop, topReach: run.atCommit?.topReach },
          "the soft edge the transition's commit left",
        ).toEqual({ fadeTop: false, topReach: "0" });
        expect(run.after).toEqual({ top: 0, fadeTop: false, topReach: "0" });
      });

      test("the rows' tab stop is a row on screen once a scroll down settles", async () => {
        const page = await open(browser!, "all", false);
        const run = await page.evaluate(async () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          // raf-read: it reads the offset, the mounted rows and their boxes, which React set before the frame.
          const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
          const key = () =>
            [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")]
              .map((row) => `${row.dataset.rowId}:${row.tabIndex}`)
              .join(",");
          const settle = async () => {
            let still = 0;
            let last = "";
            let lastTop = -1;
            for (let frames = 0; still < 30 && frames < 1200; frames += 1) {
              await frame();
              const now = key();
              still = now === last && scroller.scrollTop === lastTop ? still + 1 : 0;
              last = now;
              lastTop = scroller.scrollTop;
            }
            return still;
          };
          const stops = () => {
            const view = scroller.getBoundingClientRect();
            return [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")]
              .filter((row) => row.tabIndex === 0)
              .map((row) => {
                const box = row.getBoundingClientRect();
                return { id: row.dataset.rowId, onScreen: box.bottom > view.top && box.top < view.bottom };
              });
          };
          // At the top, the first row is the stop.
          await frame();
          scroller.dispatchEvent(
            new WheelEvent("wheel", { deltaY: -scroller.scrollTop, bubbles: true, cancelable: true }),
          );
          scroller.scrollTop = 0;
          const atTop = await settle();
          const before = stops();
          // A reader scrolls down a viewport and a half, a wheel step a frame: the rows the stop was on
          // stay mounted above the view (the warm rows reach four viewports up).
          const by = 60;
          const frames = Math.ceil((scroller.clientHeight * 1.5) / by);
          for (let index = 0; index < frames; index += 1) {
            await frame();
            scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: by, bubbles: true, cancelable: true }));
            scroller.scrollTop += by;
          }
          const settled = await settle();
          return { atTop, before, settled, top: scroller.scrollTop, after: stops() };
        });
        await page.close();
        console.log(`STALE-COMMIT ${JSON.stringify({ engine: name, case: "tab-stop", ...run })}`);
        expect(run.atTop).toBe(30);
        expect(run.before.map((stop) => stop.onScreen)).toEqual([true]);
        expect(run.settled).toBe(30);
        expect(run.top).toBeGreaterThan(600);
        // One stop, on screen: Tab into the transcript (ui/tabReach.ts keepTabOnScreen) reaches it.
        expect(
          run.after.map((stop) => stop.onScreen),
          "the rows' tab stops, on screen",
        ).toEqual([true]);
      });

      test("a pointer held past the room above the loaded rows is put back each frame", async () => {
        // Pages take far longer than the test: the room above the tail never fills.
        const page = await open(browser!, "prompts&latency=600000", false);
        const run = await page.evaluate(async () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          // raf-read: it reads the offset, which the scroll and the transcript's frame set before the frame.
          const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
          const settle = async () => {
            let still = 0;
            let lastTop = -1;
            for (let frames = 0; still < 20 && frames < 1200; frames += 1) {
              await frame();
              still = scroller.scrollTop === lastTop ? still + 1 : 0;
              lastTop = scroller.scrollTop;
            }
            return still;
          };
          // Up to the loaded rows' top: a wheel into the room is given back, so the view rests at its edge.
          await settle();
          await frame();
          scroller.dispatchEvent(
            new WheelEvent("wheel", { deltaY: -scroller.scrollTop, bubbles: true, cancelable: true }),
          );
          scroller.scrollTop = 0;
          const atEdge = await settle();
          const edge = scroller.scrollTop;
          // A press on a row (not the scrollbar), held, that drags the view 200 px into the room: its
          // target is noted there and the view held at the edge.
          const row = scroller.querySelector<HTMLElement>(".acpmux-row[data-row-id]")!;
          const box = row.getBoundingClientRect();
          const point = {
            clientX: box.left + 20,
            clientY: Math.max(box.top + 2, scroller.getBoundingClientRect().top + 40),
          };
          row.dispatchEvent(
            new PointerEvent("pointerdown", {
              ...point,
              bubbles: true,
              buttons: 1,
              pointerType: "mouse",
              isPrimary: true,
            }),
          );
          await frame();
          scroller.scrollTop = edge - 200;
          const intoRoom = await settle();
          const heldAt = scroller.scrollTop;
          // Still held, the reader moves 40 px down, off the room's edge into the rows: a scroll the
          // row window takes without a render. The next frames put the view back at the edge.
          await frame();
          scroller.scrollTop = heldAt + 40;
          const moved = scroller.scrollTop;
          const tops: number[] = [];
          for (let frames = 0; frames < 4; frames += 1) {
            await frame();
            tops.push(scroller.scrollTop);
          }
          document.dispatchEvent(
            new PointerEvent("pointerup", {
              ...point,
              bubbles: true,
              buttons: 0,
              pointerType: "mouse",
              isPrimary: true,
            }),
          );
          return { atEdge, edge, intoRoom, heldAt, moved, tops };
        });
        await page.close();
        console.log(`STALE-COMMIT ${JSON.stringify({ engine: name, case: "hold", ...run })}`);
        expect(run.atEdge, "resting at the loaded rows' top").toBe(20);
        expect(run.edge, "room above the loaded rows").toBeGreaterThan(200);
        expect(run.intoRoom).toBe(20);
        expect(Math.abs(run.heldAt - run.edge), "the drag into the room held at its edge").toBeLessThanOrEqual(1);
        expect(run.moved - run.heldAt, "the move off the edge took").toBeGreaterThan(30);
        // Back at the edge by the second frame after the move (its scroll event's frame), and kept there.
        expect(
          run.tops.slice(1).map((top) => Math.abs(top - run.heldAt) <= 1),
          "frames after the move at the room's edge",
        ).toEqual([true, true, true]);
      });
    });
  }
});
