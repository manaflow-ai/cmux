// cmux-web-test-timeout: 600
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A slow scroll up while the room held above the loaded rows for older history is short of its
// estimate (conversation/olderReserve.ts) pays part of each step into that room, and the anchor moves
// the offset by the same amount, so what the reader sees moves exactly as they scrolled. The room is
// where the loaded rows start: a payback must move one element, not every mounted row. Each frame
// re-placed every mounted row (`top` held the room), about 85 RowFrame renders a frame.
//
// The real pane (`?mock`), a chat of 300 turns (`cmuxAcpmuxDebug.loadSeed`), older history not loaded,
// parked about 540 px up from the latest row and held still. Then 60 frames each a wheel event of
// -2 px and the offset moved -2 px.
// - "payback": a row in view moves +120 px on screen, and no row that stayed mounted renders but
//   for the roving Tab stop moving to the row now first in view (RowFrame and RowContent counted per
//   component, support/fiberRenders.ts; any work inside a row element, support/commitRenders.ts).
// - "pixels": every mounted row is drawn exactly where its placement puts it: the spacer's top plus
//   the offsets written on the row and on every element between it and the spacer (its `top` and
//   `margin-top`, React's props and the sub-pixel scroll origin). Checked on every frame of a payback
//   (the room fractional on some, the sub-pixel origin nonzero on some), and after an older page lands.
// Real Chromium and WebKit; CI fails the file when one cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installRowRenderCounter, type RowRenderCount } from "./support/commitRenders";
import { installFiberRenders, startFiberRenders, stopFiberRenders } from "./support/fiberRenders";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Parity = {
  /// Rows checked, over every sample.
  rows: number;
  /// The largest distance between a row's drawn top and its placed top, px.
  worst: number;
  worstRow?: string;
  /// Samples whose room was fractional, and whose thread held a sub-pixel scroll origin.
  fractionalRoom: number;
  subPixelOrigin: number;
  samples: number;
  /// Each row's drawn top less the room and the sub-pixel scroll origin, as first seen: its place
  /// from the first loaded row, which a payback leaves as it is (no style read: the room is
  /// `data-older-room`, the row's top its box).
  fromFirst: Record<string, number>;
  /// The most a row's place from the first loaded row moved between samples, px.
  drift: number;
  driftRow?: string;
};

await requireBrowserLane("transcript-scroll-up-room-renders.test.ts", async () => {
  setDefaultTimeout(560_000);
  const FRAMES = 60;
  const STEP = -2;
  const ROW_COMPONENTS = ["RowFrame", "RowContent"];
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  /// In the page: each mounted row's drawn top against its placed top. Installed once per page as
  /// `__cmuxRowParity(parity)`, which adds one sample to `parity`.
  function installParity() {
    const propsOf = (node: Element): { style?: Record<string, unknown> } | undefined => {
      const key = Object.keys(node).find((name) => name.startsWith("__reactProps$"));
      return key ? (node as unknown as Record<string, { style?: Record<string, unknown> }>)[key] : undefined;
    };
    const px = (value: unknown): number => {
      if (typeof value === "number") return value;
      if (typeof value === "string" && value.endsWith("px")) return Number.parseFloat(value);
      return 0;
    };
    /// The offset an element's own inline style moves it by: React's numbers where React wrote them
    /// (exact, as the transcript computed them), else the inline style (the sub-pixel scroll origin,
    /// written as a property, is less than a pixel).
    const offsetOf = (node: HTMLElement) => {
      const style = propsOf(node)?.style ?? {};
      const top = "top" in style ? px(style.top) : px(node.style.top);
      const margin = "marginTop" in style ? px(style.marginTop) : px(node.style.marginTop);
      return top + margin;
    };
    (window as any).__cmuxRowParity = (parity: {
      rows: number;
      worst: number;
      worstRow?: string;
      fractionalRoom: number;
      subPixelOrigin: number;
      samples: number;
      fromFirst: Record<string, number>;
      drift: number;
      driftRow?: string;
    }) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const spacer = scroller.querySelector<HTMLElement>(":scope > .acpmux-spacer")!;
      const thread = spacer.querySelector<HTMLElement>(".acpmux-thread")!;
      const room = Number(spacer.dataset.olderRoom ?? 0);
      parity.samples += 1;
      if (Math.abs(room - Math.round(room)) > 1e-6) parity.fractionalRoom += 1;
      const subPixel = px(thread.style.marginTop);
      if (Math.abs(subPixel) > 1e-6) parity.subPixelOrigin += 1;
      const spacerTop = spacer.getBoundingClientRect().top;
      for (const row of thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]")) {
        let placed = 0;
        for (let at: HTMLElement | null = row; at && at !== spacer; at = at.parentElement) placed += offsetOf(at);
        const drawn = row.getBoundingClientRect().top - spacerTop;
        const off = Math.abs(drawn - placed);
        parity.rows += 1;
        const id = row.dataset.rowId!;
        const fromFirst = drawn - room - subPixel;
        const was = parity.fromFirst[id];
        if (was === undefined) parity.fromFirst[id] = fromFirst;
        else if (Math.abs(fromFirst - was) > parity.drift) {
          parity.drift = Math.abs(fromFirst - was);
          parity.driftRow = `${id} from the first row ${was} then ${fromFirst} room ${room}`;
        }
        if (off > parity.worst) {
          parity.worst = off;
          parity.worstRow = `${row.dataset.rowId} drawn ${drawn} placed ${placed} room ${room}`;
        }
      }
    };
  }

  /// The pane with the long chat, parked about 540 px up from the latest row (120 px wheel steps), held
  /// still for 90 frames: room above the loaded rows is still owed.
  async function openParked(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await installFiberRenders(page);
    await page.addInitScript(installRowRenderCounter);
    await page.addInitScript(installParity);
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    const parked = await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      // raf-read: the offset and room are read after the frame's commit.
      const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
      for (let left = 540; left > 0; left -= 120) {
        const by = -Math.min(120, left);
        scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: by, bubbles: true, cancelable: true }));
        scroller.scrollTop += by;
        await frame();
      }
      for (let n = 0; n < 90; n += 1) await frame();
      const spacer = scroller.querySelector<HTMLElement>(":scope > .acpmux-spacer")!;
      return {
        top: scroller.scrollTop,
        room: Number(spacer.dataset.olderRoom ?? 0),
        loadsOlder: spacer.dataset.loadsOlder !== undefined,
        below: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
      };
    });
    console.log(`SCROLL-UP-ROOM parked ${JSON.stringify(parked)}`);
    expect(parked.loadsOlder, "older history is still to load").toBe(true);
    expect(parked.room, "room is held above the loaded rows").toBeGreaterThan(0);
    return page;
  }

  /// 60 frames, each a wheel event of -2 px and the offset moved -2 px; a probe row in the middle of
  /// the view is followed on screen; parity is sampled every frame when `parity` is on.
  async function paybackFrames(page: Page, parity: boolean) {
    await page.evaluate(() => {
      (globalThis as any).__cmuxRowRenders.begin(document.querySelector(".acpmux-scroll"), ".acpmux-row");
    });
    await startFiberRenders(page);
    const run = await page.evaluate(
      async ([frames, step, parity]) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const spacer = scroller.querySelector<HTMLElement>(":scope > .acpmux-spacer")!;
        // raf-read: one offset write a frame; the rows and boxes read are committed before the frame.
        const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
        const ids = () =>
          [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].map((row) => row.dataset.rowId!);
        const box = scroller.getBoundingClientRect();
        const probe = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].find((row) => {
          const rect = row.getBoundingClientRect();
          return rect.top > box.top + 100 && rect.bottom < box.bottom - 100;
        });
        const probeTop = probe?.getBoundingClientRect().top ?? Number.NaN;
        const before = ids();
        const roomBefore = Number(spacer.dataset.olderRoom ?? 0);
        const startTop = scroller.scrollTop;
        // What changed inside the mounted rows over the run (a row that rendered for a reason shows
        // here), by row and attribute: for the log. The one row that is a Tab stop (`tabindex` 0, the
        // first row in view) moves as rows pass the view's top: the reader's own scroll, which the
        // payback leaves alone, and the only render a row may take here (`tabMoves`).
        const changed = new Map<string, number>();
        const tabRows = new Set<string>();
        let tabMoves = 0;
        const watch = new MutationObserver((records) => {
          for (const record of records) {
            const node = record.target instanceof Element ? record.target : record.target.parentElement;
            const row = node?.closest<HTMLElement>(".acpmux-row[data-row-id]");
            if (!row) continue;
            const what = `${row.dataset.rowId}:${record.type === "attributes" ? `${node === row ? "" : `${node!.tagName.toLowerCase()}.`}${record.attributeName}=${(node as Element).getAttribute(record.attributeName!)}<-${record.oldValue}` : record.type}`;
            changed.set(what, (changed.get(what) ?? 0) + 1);
            if (node === row && record.attributeName === "tabindex") {
              tabRows.add(row.dataset.rowId!);
              tabMoves += 1;
            }
          }
        });
        watch.observe(scroller.querySelector(".acpmux-thread")!, {
          subtree: true,
          attributes: true,
          attributeOldValue: true,
          childList: true,
          characterData: true,
        });
        const sample: any = {
          rows: 0,
          worst: 0,
          fractionalRoom: 0,
          subPixelOrigin: 0,
          samples: 0,
          fromFirst: {},
          drift: 0,
        };
        let windowChanges = 0;
        let last = before.join(",");
        const check = () => {
          const key = ids().join(",");
          if (key !== last) windowChanges += 1;
          last = key;
          if (parity) (window as any).__cmuxRowParity(sample);
        };
        for (let index = 0; index < frames; index += 1) {
          await frame();
          check();
          scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: step, bubbles: true, cancelable: true }));
          scroller.scrollTop += step;
        }
        for (let index = 0; index < 2; index += 1) {
          await frame();
          check();
        }
        const after = ids();
        watch.disconnect();
        return {
          probe: probe?.dataset.rowId,
          probeMoved: probe?.isConnected ? probe.getBoundingClientRect().top - probeTop : Number.NaN,
          offsetMoved: scroller.scrollTop - startTop,
          // Paid into the room: it grows toward its estimate.
          roomPaid: Number(spacer.dataset.olderRoom ?? 0) - roomBefore,
          mounted: before.length,
          stayed: after.filter((id) => before.includes(id)).length,
          windowChanges,
          tabRows: tabRows.size,
          tabMoves,
          changed: [...changed].slice(0, 16).map(([what, times]) => `${what} x${times}`),
          parity: sample,
        };
      },
      [FRAMES, STEP, parity] as const,
    );
    const fibers = await stopFiberRenders(page);
    const rows = (await page.evaluate(() => (globalThis as any).__cmuxRowRenders.end())) as RowRenderCount;
    const rowComponents = ROW_COMPONENTS.reduce((sum, name) => sum + (fibers.counts[name] ?? 0), 0);
    const perFrame = (value: number) => Math.round((value / FRAMES) * 100) / 100;
    return { run: run as typeof run & { parity: Parity }, fibers, rows, rowComponents, perFrame };
  }

  /// A parity sample without its per-row places, for the log.
  const brief = ({ fromFirst: _, ...rest }: Parity) => rest;

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`transcript-scroll-up-room-renders (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a slow scroll up that pays into the room renders no row that stays mounted", async () => {
        const page = await openParked(browser!);
        const { run, fibers, rows, rowComponents, perFrame } = await paybackFrames(page, false);
        await page.close();
        console.log(
          `SCROLL-UP-ROOM ${JSON.stringify({ engine: name, case: "payback", frames: FRAMES, ...run, parity: undefined, commits: fibers.commits, row_frame: fibers.counts.RowFrame ?? 0, row_content: fibers.counts.RowContent ?? 0, rows, per_frame: { row_frame: perFrame(fibers.counts.RowFrame ?? 0), row_components: perFrame(rowComponents), transcript_view: perFrame(fibers.counts.TranscriptView ?? 0) } })}`,
        );
        // The run is what it says: room was paid, and the rows on screen moved as the reader scrolled.
        expect(run.roomPaid, "room paid back over the run").toBeGreaterThan(10);
        expect(run.probe, "a row in the middle of the view").toBeDefined();
        expect(
          Math.abs(run.probeMoved - -STEP * FRAMES),
          "the row in view moved +120 px on screen",
        ).toBeLessThanOrEqual(2);
        // No row that was mounted before the run rendered but for the Tab stop moving, and the row
        // components rendered only for those and for rows the run mounted (at most twice each: a mount
        // and its measure; a Tab stop's move is one render of each of its two rows). Every row rendered
        // each frame (60 renders of each of the 38 mounted rows).
        expect(rows.rerendered, "rows mounted before the run that rendered").toBeLessThanOrEqual(run.tabRows);
        expect(rowComponents, "RowFrame and RowContent renders").toBeLessThanOrEqual(2 * run.tabMoves + 2 * rows.added);
      });

      test("every mounted row draws where it is placed: at rest, through a payback, after an older page lands", async () => {
        const page = await openParked(browser!);
        const rest = await page.evaluate(() => {
          const parity = {
            rows: 0,
            worst: 0,
            fractionalRoom: 0,
            subPixelOrigin: 0,
            samples: 0,
            fromFirst: {},
            drift: 0,
          };
          (window as any).__cmuxRowParity(parity);
          return parity as Parity;
        });
        const { run } = await paybackFrames(page, true);
        // Up until an older page lands: the rows it brings go above the loaded ones, so a row still
        // mounted from the frame before stands further down the list (`aria-posinset`). Then held
        // still, and checked again.
        const landed = await page.evaluate(async () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const spacer = scroller.querySelector<HTMLElement>(":scope > .acpmux-spacer")!;
          // raf-read: the room is read after each frame's commit.
          const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
          const roomNow = () => Number(spacer.dataset.olderRoom ?? 0);
          const rowCount = () => scroller.querySelectorAll(".acpmux-row[data-row-id]").length;
          const places = () =>
            new Map(
              [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].map((row) => [
                row.dataset.rowId!,
                Number(row.getAttribute("aria-posinset")),
              ]),
            );
          let seen = places();
          let room = roomNow();
          let roomBefore = room;
          let came = 0;
          let frames = 0;
          for (; frames < 900 && came <= 0; frames += 1) {
            scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -400, bubbles: true, cancelable: true }));
            scroller.scrollTop -= 400;
            await frame();
            const now = places();
            for (const [id, at] of now) {
              const was = seen.get(id);
              if (was !== undefined && at > was) came = Math.max(came, at - was);
            }
            roomBefore = room;
            room = roomNow();
            seen = now;
          }
          // The room the page took its rows' height from, in the frame it landed.
          const roomTaken = roomBefore - room;
          for (let n = 0; n < 60; n += 1) await frame();
          const parity = {
            rows: 0,
            worst: 0,
            fractionalRoom: 0,
            subPixelOrigin: 0,
            samples: 0,
            fromFirst: {},
            drift: 0,
          };
          (window as any).__cmuxRowParity(parity);
          return { frames, came, roomTaken, room: roomNow(), mounted: rowCount(), parity: parity as Parity };
        });
        await page.close();
        console.log(
          `SCROLL-UP-ROOM ${JSON.stringify({ engine: name, case: "pixels", rest: brief(rest), payback: brief(run.parity), landed: { ...landed, parity: brief(landed.parity) } })}`,
        );
        // The run covers what it says: a fractional room, a sub-pixel scroll origin, a page that landed.
        expect(rest.rows, "rows checked at rest").toBeGreaterThan(0);
        expect(run.parity.fractionalRoom, "payback frames with a fractional room").toBeGreaterThan(0);
        expect(run.parity.subPixelOrigin, "payback frames with a sub-pixel scroll origin").toBeGreaterThan(0);
        expect(landed.came, "rows an older page brought above the loaded ones").toBeGreaterThan(0);
        expect(landed.roomTaken, "the room the page took its rows' height from").toBeGreaterThan(0);
        // Every row is drawn at its placed top, to 0.01 px.
        expect(rest.worst, `at rest: ${rest.worstRow}`).toBeLessThanOrEqual(0.01);
        expect(run.parity.worst, `through the payback: ${run.parity.worstRow}`).toBeLessThanOrEqual(0.01);
        // And a payback moved no row from its place under the first loaded row: it moved the room alone.
        expect(run.parity.drift, `through the payback: ${run.parity.driftRow}`).toBeLessThanOrEqual(0.01);
        expect(landed.parity.worst, `after the page landed: ${landed.parity.worstRow}`).toBeLessThanOrEqual(0.01);
      });
    });
  }
});
