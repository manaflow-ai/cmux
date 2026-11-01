// l10n-allow-file: deterministic transcript fixture text.
// Real Chromium: input must win over a streamed layout before its scroll event arrives.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("scroll-intent-rail.test.ts", async () => {
  setDefaultTimeout(120_000);
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
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("wheel input wins over a streamed follow correction in the same turn", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRowsSync" in window);
    const rows = Array.from({ length: 40 }, (_, index) => [
      { id: `intent-${index}-user`, kind: "user", text: `Prompt ${index}`, version: 1, at: index },
      {
        id: `intent-${index}-answer`,
        kind: "assistant",
        text: "The keeper watches the light sweep across the water.",
        version: 1,
        at: index,
      },
      { id: `intent-${index}-end`, kind: "turnSummary", status: "completed", durationMs: 1, version: 1, at: index },
    ]).flat();
    await page.evaluate((shown) => (window as any).__showRowsSync(shown), rows);
    await page.evaluate(async () => {
      for (let frame = 0; frame < 8; frame += 1) await window.cmuxPaintFrame();
    });
    const evidenceDir = process.env.SCROLL_INTENT_EVIDENCE;
    if (evidenceDir) {
      await mkdir(evidenceDir, { recursive: true });
      await page.screenshot({ path: path.join(evidenceDir, "before-input.png") });
    }
    await page.evaluate((shown) => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const probe = window as any;
      probe.__writes = [];
      probe.__frames = [];
      const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
      Object.defineProperty(node, "scrollTop", {
        configurable: true,
        get() {
          return descriptor.get!.call(node);
        },
        set(value) {
          const before = descriptor.get!.call(node);
          descriptor.set!.call(node, value);
          if (probe.__input !== undefined)
            probe.__writes.push({
              at: performance.now() - probe.__input,
              before,
              after: descriptor.get!.call(node),
              caller: new Error().stack,
            });
        },
      });
      // A snapshot lands after the captured input, before the browser delivers its scroll event.
      node.addEventListener(
        "wheel",
        () => {
          probe.__input = performance.now();
          probe.__inputTop = node.scrollTop;
          probe.__showRowsSync([
            ...shown,
            {
              id: "live-answer",
              kind: "assistant",
              text: "A new streamed paragraph.\n\n".repeat(8),
              version: 1,
              at: 100,
              streaming: true,
            },
          ]);
        },
        { once: true },
      );
      probe.__stop = window.cmuxAfterPaint(() => {
        if (probe.__input === undefined) return true;
        probe.__frames.push({ at: performance.now() - probe.__input, top: node.scrollTop });
        return performance.now() - probe.__input < 1100;
      });
    }, rows);
    await page.mouse.move(450, 180);
    await page.mouse.wheel(0, -80);
    await page.waitForFunction(() => (window as any).__frames.at(-1)?.at >= 1100);
    const evidence = await page.evaluate(() => {
      const probe = window as any;
      probe.__stop();
      return { top: probe.__inputTop, frames: probe.__frames, writes: probe.__writes };
    });
    console.log("scroll-intent-production", JSON.stringify(evidence));
    if (evidenceDir) {
      await writeFile(path.join(evidenceDir, "frames.json"), JSON.stringify(evidence));
      await page.screenshot({ path: path.join(evidenceDir, "after-input.png") });
    }
    expect(evidence.frames.length).toBeGreaterThan(0);
    expect(evidence.writes.filter((write: any) => write.after > write.before + 1)).toEqual([]);
    expect(evidence.frames.filter((frame: any) => frame.top > evidence.top + 1)).toEqual([]);
    // Same-frame row-height compensation is still allowed: it must preserve the live manual
    // offset, including movement whose scroll event has not reached React yet.
    const anchor = await page.evaluate(async (shown) => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: -80 }));
      node.scrollTop -= 80;
      const line = [...node.querySelectorAll<HTMLElement>(".acpmux-row")].find(
        (row) => row.getBoundingClientRect().top >= 0,
      )!;
      const above = [...node.querySelectorAll<HTMLElement>(".acpmux-row")].find(
        (row) => row.dataset.rowId?.endsWith("-answer") && row.getBoundingClientRect().bottom < 0,
      )!.dataset.rowId;
      const before = line.getBoundingClientRect().top;
      const top = node.scrollTop;
      (window as any).__showRowsSync(
        [
          ...shown,
          {
            id: "live-answer",
            kind: "assistant",
            text: "A new streamed paragraph.\n\n".repeat(8),
            version: 1,
            at: 100,
            streaming: true,
          },
        ].map((row) =>
          row.id === above ? { ...row, text: "A taller row above the reader.\n\n".repeat(12), version: 2 } : row,
        ),
      );
      const frames: number[] = [];
      for (let frame = 0; frame < 8; frame += 1) {
        await window.cmuxPaintFrame();
        frames.push(line.getBoundingClientRect().top - before);
      }
      return { frames, correction: node.scrollTop - top };
    }, rows);
    await page.close();
    console.log("scroll-intent-anchor", JSON.stringify(anchor));
    expect(anchor.correction).toBeGreaterThan(20);
    expect(anchor.frames.every((delta) => Math.abs(delta) <= 1)).toBe(true);
  });
  test("manual input cancels a footnote ride before another painted frame", async () => {
    const page = await browser!.newPage();
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRowsSync" in window);
    const result = await page.evaluate(async () => {
      (window as any).__showRowsSync([
        {
          id: "note",
          kind: "assistant",
          version: 1,
          at: 1,
          text:
            "A reference[^n].\n\n" + "A long paragraph between reference and note.\n\n".repeat(60) + "[^n]: The note.",
        },
      ]);
      for (let frame = 0; frame < 8; frame++) await window.cmuxPaintFrame();
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: -1 }));
      node.scrollTop = 0;
      for (let frame = 0; frame < 3; frame++) await window.cmuxPaintFrame();
      node.querySelector<HTMLButtonElement>(".cv-fnref button")!.click();
      do {
        await window.cmuxPaintFrame();
      } while (node.scrollTop === 0);
      node.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, buttons: 1 }));
      const stopped = node.scrollTop;
      const frames: number[] = [];
      for (let frame = 0; frame < 12; frame++) {
        await window.cmuxPaintFrame();
        frames.push(node.scrollTop);
      }
      return { stopped, end: node.scrollHeight - node.clientHeight, frames };
    });
    await page.close();
    console.log("scroll-intent-footnote", JSON.stringify(result));
    expect(result.stopped).toBeLessThan(result.end);
    expect(result.frames).toEqual(result.frames.map(() => result.stopped));
  });
  test("manual inputs invalidate explicit requests and hold until one second after release", async () => {
    const page = await browser!.newPage();
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    const result = await page.evaluate(async (modulePath) => {
      const { attachUserScrollIntent, userScrollIntent } = await import(modulePath);
      const node = document.createElement("div");
      node.tabIndex = 0;
      document.body.append(node);
      let now = 0;
      const clock = performance.now.bind(performance);
      performance.now = () => now;
      const detach = attachUserScrollIntent(node);
      const intent = userScrollIntent(node);
      const held: boolean[] = [];
      for (const event of [
        new WheelEvent("wheel"),
        new Event("touchstart"),
        ...["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "].map(
          (key) => new KeyboardEvent("keydown", { key, bubbles: true }),
        ),
      ]) {
        const request = intent.request();
        node.dispatchEvent(event);
        held.push(intent.isHeld() && !request());
        document.dispatchEvent(new Event("touchend"));
      }
      node.dispatchEvent(new PointerEvent("pointerdown"));
      now = 2000;
      held.push(intent.isHeld());
      document.dispatchEvent(new PointerEvent("pointerup"));
      now = 2999;
      held.push(intent.isHeld());
      now = 3000;
      held.push(!intent.isHeld());
      const { animateScroll } = await import(
        modulePath.replace("conversation/userScroll.ts", "threadMinimap/scrollMotion.ts")
      );
      Object.defineProperty(node, "scrollTop", { value: 0, writable: true });
      node.dispatchEvent(new WheelEvent("wheel"));
      animateScroll(node, () => 100, 0, [0, 0, 1, 1]);
      held.push(node.scrollTop === 0);
      animateScroll(node, () => 100, 0, [0, 0, 1, 1], undefined, undefined, { explicit: true });
      held.push(node.scrollTop === 100);
      // A scrollbar drag can lose pointerup outside the window. A buttons=0 move clears the
      // pressed state so later hovering does not keep cancelling explicit motion.
      now = 5001;
      const hoverRequest = intent.request();
      document.dispatchEvent(new PointerEvent("pointermove", { buttons: 0, bubbles: true }));
      held.push(hoverRequest() && !intent.isHeld());
      node.dispatchEvent(new PointerEvent("pointerdown", { buttons: 1, bubbles: true }));
      window.dispatchEvent(new Event("blur"));
      now = 6001;
      held.push(!intent.isHeld());
      animateScroll(node, () => 500, 60_000, [0, 0, 1, 1], undefined, undefined, { explicit: true });
      node.dispatchEvent(new WheelEvent("wheel"));
      await new Promise(requestAnimationFrame);
      held.push(node.scrollTop === 100);
      detach();
      const request = intent.request();
      node.dispatchEvent(new WheelEvent("wheel"));
      held.push(request() && !intent.isHeld());
      performance.now = clock;
      node.remove();
      return held;
    }, "/src/agent-session/acpmux/conversation/userScroll.ts");
    await page.close();
    expect(result.every(Boolean)).toBe(true);
  });

  test("a pending JumpPill reveal cannot pull back after manual input", async () => {
    const page = await browser!.newPage();
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    const result = await page.evaluate(
      async (modules) => {
        const { attachUserScrollIntent } = await import(modules.intent);
        const { revealTurnWhenShown } = await import(modules.links);
        const node = document.createElement("div");
        node.className = "acpmux-scroll";
        document.body.append(node);
        const detach = attachUserScrollIntent(node);
        const pending = revealTurnWhenShown("late", node);
        node.dispatchEvent(new WheelEvent("wheel"));
        const cancelled = await pending;
        node.innerHTML = '<div data-turn-id="late">Late prompt</div>';
        let moved = false;
        (node.firstElementChild as HTMLElement).scrollIntoView = () => {
          moved = true;
        };
        // A new explicit click during the hold remains allowed.
        const explicit = await revealTurnWhenShown("late", node);
        detach();
        node.remove();
        return { cancelled, explicit, moved };
      },
      { intent: "/src/agent-session/acpmux/conversation/userScroll.ts", links: "/src/agent-session/acpmux/links.ts" },
    );
    await page.close();
    expect(result).toEqual({ cancelled: false, explicit: true, moved: true });
  });
});
