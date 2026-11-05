// The real shared anchor in Chromium: stylesheet caps and available room both hold before the
// first visible placement, with no ResizeObserver correction one frame later.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("anchor-first-frame.test.ts", async () => {
  setDefaultTimeout(60_000);
  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".anchor-first-frame-"));
  const entry = path.join(dir, "entry.tsx");
  fs.writeFileSync(
    entry,
    `
    import { useLayoutEffect, useRef, useState } from "react";
    import { createRoot } from "react-dom/client";
    import { flushSync } from "react-dom";
    import { useUiAnchor } from "../../src/ui/anchor";
    const state = window.anchorTest = { rects: [], shifts: [], hiddenFrames: 0, room: null, done: false };
    const record = () => {
      const popup = document.querySelector(".popup");
      if (!popup || getComputedStyle(popup).visibility !== "visible") return;
      const {x,y,width,height} = popup.getBoundingClientRect();
      state.rects.push({x,y,width,height});
    };
    new PerformanceObserver(list => state.shifts.push(...list.getEntries().filter(e => !e.hadRecentInput)))
      .observe({type:"layout-shift", buffered:true});
    function Fixture() {
      const trigger = useRef(null), popup = useRef(null);
      const [open, setOpen] = useState(false);
      window.openPopup = () => flushSync(() => setOpen(true));
      const style = useUiAnchor(trigger, popup, open, {side:"above"});
      state.room = style.maxHeight;
      const ownHeight = document.getElementById("root").dataset.caller
        ? {maxHeight: typeof style.maxHeight === "number" ? style.maxHeight : 480, minHeight: 220} : {};
      useLayoutEffect(record);
      return <><button ref={trigger}>+</button>{open &&
        <div ref={popup} className="popup" style={{...style,...ownHeight}}><div className="content" /></div>}</>;
    }
    flushSync(() => createRoot(document.getElementById("root")).render(<Fixture />));
    window.recordPopup = record;
  `,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  fs.rmSync(dir, { recursive: true, force: true });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0].text();
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function open(height: number, scale = 1, cap = "min(480px,70vh)", caller = false): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 760, height } });
    await page.setContent(`<style>
      body{margin:0;min-height:1200px}#root{position:relative;width:calc(100vw / ${scale});height:calc(100vh / ${scale});transform:scale(${scale});transform-origin:top left}
      button{position:absolute;left:100px;bottom:28px;width:28px;height:24px}
      .popup{width:360px;max-height:${cap};padding:4px;box-sizing:border-box;overflow:auto;background:#ddd}
      .content{height:399px}
    </style><div id="root"${caller ? ' data-caller="true"' : ""}></div>`);
    await installPaintedFrames(page);
    await page.addScriptTag({ content: script });
    return page;
  }

  async function sample(page: Page, action: "open" | "scroll" | "grow" | "none") {
    await page.evaluate((reveal) => {
      const win = window as any;
      win.anchorTest.rects = [];
      win.anchorTest.shifts = [];
      win.anchorTest.hiddenFrames = 0;
      win.anchorTest.done = false;
      let frames = 0;
      window.cmuxAfterPaint(() => {
        const popup = document.querySelector(".popup");
        if (popup && getComputedStyle(popup).visibility === "hidden") win.anchorTest.hiddenFrames++;
        win.recordPopup();
        if (++frames === 8) {
          win.anchorTest.done = true;
          return false;
        }
      });
      if (reveal === "open") win.openPopup();
      if (reveal === "scroll") window.scrollTo(0, 20);
      if (reveal === "grow") (document.querySelector(".content") as HTMLElement).style.height = "420px";
    }, action);
    await page.waitForFunction(() => (window as any).anchorTest.done);
    return page.evaluate(() => {
      const { rects, shifts, hiddenFrames, room } = (window as any).anchorTest;
      return {
        rects: rects as { x: number; y: number; width: number; height: number }[],
        hiddenFrames: hiddenFrames as number,
        room: room as unknown,
        cls: shifts.reduce((sum: number, entry: any) => sum + entry.value, 0) as number,
      };
    });
  }

  test("CSS min/vh cap holds on the first visible frame and recomputes while open", async () => {
    const page = await open(560);
    const first = await sample(page, "open");
    expect(first.hiddenFrames).toBe(0);
    expect(first.rects.length).toBeGreaterThan(1);
    expect(first.rects).toEqual(first.rects.map(() => first.rects[0]));
    expect(first.rects[0].height).toBe(392);
    expect(first.cls).toBe(0);
    await page.setViewportSize({ width: 760, height: 800 });
    const resized = await sample(page, "none");
    expect(resized.rects.at(-1)!.height).toBe(407);
    await page.setViewportSize({ width: 760, height: 400 });
    const short = await sample(page, "none");
    expect(short.rects.at(-1)!.height).toBe(280);
    await page.close();
  });

  test("final constrained rect stays in short viewports and transformed roots", async () => {
    for (const [height, scale, cap] of [
      [240, 1, "calc(100vh - 24px)"],
      [560, 1.25, "min(480px,70vh)"],
    ] as const) {
      const page = await open(height, scale, cap);
      const result = await sample(page, "open");
      expect(result.hiddenFrames).toBe(0);
      expect(result.rects.length).toBeGreaterThan(1);
      expect(result.rects).toEqual(result.rects.map(() => result.rects[0]));
      expect(result.cls).toBe(0);
      for (const rect of result.rects) {
        // The transformed coordinate conversion is quantized to the engine's 1/64 CSS pixel.
        expect(rect.y).toBeGreaterThanOrEqual(8 - 1 / 64);
        expect(rect.y + rect.height).toBeLessThanOrEqual(height - 8 + 1 / 64);
      }
      await page.close();
    }
  });

  test("caller-owned numeric bounds and scroll/ResizeObserver updates keep their API and settle", async () => {
    const caller = await open(560, 1, "min(480px,70vh)", true);
    const owned = await sample(caller, "open");
    expect(typeof owned.room).toBe("number");
    expect(owned.room).toBe(494);
    expect(owned.rects.at(-1)!.height).toBe(407);
    await caller.close();
    const page = await open(560);
    await sample(page, "open");
    for (const action of ["scroll", "grow"] as const) {
      const updated = await sample(page, action);
      expect(updated.hiddenFrames).toBe(0);
      expect(updated.rects).toEqual(updated.rects.map(() => updated.rects[0]));
      expect(updated.rects.at(-1)!.height).toBe(392);
      expect(updated.cls).toBe(0);
    }
    await page.close();
  });
});
