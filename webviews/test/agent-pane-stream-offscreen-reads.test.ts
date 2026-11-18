// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A streamed chunk's work follows the rows in view, not the rows mounted (CMUX-571; Leo, 2026-11-12:
// "infinite everything feels like nothing"). The transcript mounts a viewport of history above the view
// and warm rows around it (VirtualTranscript.tsx HISTORY_VIEWPORTS, WARM_VIEWPORTS), so a chat of short
// turns mounts about twice the rows it shows (bench/transcript-replay.bench.ts: about 60 against 31).
// A layout or style read of a mounted row out of view, or a DOM walk over every mounted row, made a
// streamed token cost more in a god chat than in a small one.
//
// The real pane (`?mock`), a chat of heavy turns seeded through attach, then one text-only turn streamed
// at full speed. Every layout, style and animation read the page's script makes while it streams is
// counted by what it read: a mounted row out of view (or an element in one), and every query or
// animation walk over the whole thread. Each site is named by its caller, so a failure says where.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// Installed in the page before the stream: wraps the reads and counts those that touch a mounted row
/// out of view, by caller. The wrapped originals do the reading, so the page's behavior is the same.
function installOffscreenProbe() {
  type Site = { count: number; what: string };
  const w = window as unknown as {
    __offscreen: { on: boolean; sites: Map<string, Site>; reads: number; offscreen: number; walks: number };
  };
  const state = { on: false, sites: new Map<string, Site>(), reads: 0, offscreen: 0, walks: 0 };
  w.__offscreen = state;
  const rect = Element.prototype.getBoundingClientRect;
  const caller = () => {
    const lines = (new Error().stack ?? "").split("\n").slice(3, 6);
    return lines
      .map((line) =>
        line
          .trim()
          .replace(/\?[^:)]*/, "")
          .replace(/https?:\/\/[^/]+/, ""),
      )
      .join(" < ");
  };
  const note = (what: string) => {
    const at = `${what} @ ${caller()}`;
    const site = state.sites.get(at);
    if (site) site.count += 1;
    else state.sites.set(at, { count: 1, what });
  };
  let inside = false;
  /// The mounted row `node` lies in when that row is out of the scroller's view.
  const offscreenRow = (node: unknown): Element | undefined => {
    if (!(node instanceof Element)) return undefined;
    const row = node.closest(".acpmux-row");
    const scroller = row?.closest(".acpmux-scroll");
    if (!row || !scroller) return undefined;
    const view = rect.call(scroller);
    const box = rect.call(row);
    return box.bottom <= view.top || box.top >= view.bottom ? row : undefined;
  };
  const count = (what: string, node: unknown) => {
    if (!state.on || inside) return;
    inside = true;
    try {
      state.reads += 1;
      if (offscreenRow(node)) {
        state.offscreen += 1;
        note(`offscreen ${what}`);
      }
    } finally {
      inside = false;
    }
  };
  /// A query that looks for transcript rows (or anything) under the thread, its scroller or the
  /// document: it matches every element of every mounted row.
  const walk = (what: string, node: unknown, selector: string) => {
    if (!state.on || inside) return;
    inside = true;
    try {
      const overRows =
        node instanceof Document
          ? /acpmux-row|data-row-id/.test(selector)
          : node instanceof Element &&
            (node.matches(".acpmux-thread, .acpmux-scroll, .acpmux-spacer") ||
              (/acpmux-row|data-row-id/.test(selector) && node.querySelector(".acpmux-thread") !== null));
      if (!overRows) return;
      state.walks += 1;
      note(`walk ${what} ${selector}`);
    } finally {
      inside = false;
    }
  };
  const wrapMethod = (proto: object, name: string, before: (self: unknown, args: unknown[]) => void) => {
    const original = (proto as Record<string, (...args: unknown[]) => unknown>)[name]!;
    Object.defineProperty(proto, name, {
      configurable: true,
      writable: true,
      value: function (this: unknown, ...args: unknown[]) {
        before(this, args);
        return original.apply(this, args);
      },
    });
  };
  const wrapGetter = (proto: object, name: string) => {
    const descriptor = Object.getOwnPropertyDescriptor(proto, name)!;
    Object.defineProperty(proto, name, {
      configurable: true,
      get(this: unknown) {
        count(name, this);
        return descriptor.get!.call(this);
      },
    });
  };
  wrapMethod(Element.prototype, "getBoundingClientRect", (self) => count("getBoundingClientRect", self));
  wrapMethod(Element.prototype, "getClientRects", (self) => count("getClientRects", self));
  // An animation read over the thread's subtree reads the page's animations, not its elements: named, not counted.
  wrapMethod(Element.prototype, "getAnimations", (self, args) => {
    count("getAnimations", self);
    if (state.on && !inside && (args[0] as { subtree?: boolean } | undefined)?.subtree) note("getAnimations(subtree)");
  });
  for (const proto of [Element.prototype, Document.prototype])
    for (const name of ["querySelector", "querySelectorAll"])
      wrapMethod(proto, name, (self, args) => walk(name, self, String(args[0])));
  for (const name of ["offsetTop", "offsetHeight", "offsetWidth", "offsetLeft"])
    wrapGetter(HTMLElement.prototype, name);
  for (const name of ["clientHeight", "clientWidth", "scrollHeight"]) wrapGetter(Element.prototype, name);
  const computed = window.getComputedStyle;
  window.getComputedStyle = function (element: Element, pseudo?: string | null) {
    count("getComputedStyle", element);
    return computed.call(window, element, pseudo);
  } as typeof window.getComputedStyle;
}

await requireBrowserLane("agent-pane-stream-offscreen-reads.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a streamed chunk reads no mounted row out of view and walks no mounted row", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(700))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.evaluate(installOffscreenProbe);
    const mounted = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      const inView = rows.filter((row) => {
        const box = row.getBoundingClientRect();
        return box.bottom > view.top && box.top < view.bottom;
      }).length;
      return { mounted: rows.length, inView };
    });
    await page.evaluate(() => ((window as any).__offscreen.on = true));
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({
        seconds: 4,
        chunk_chars: 24,
        chunk_ms: 12,
        tool_every: 0,
        scroll_speed: 0,
      }),
    )) as Record<string, any>;
    const probe = await page.evaluate(() => {
      const state = (window as any).__offscreen;
      state.on = false;
      return {
        reads: state.reads as number,
        offscreen: state.offscreen as number,
        walks: state.walks as number,
        sites: [...(state.sites as Map<string, { count: number }>).entries()]
          .map(([at, site]) => ({ at, count: site.count }))
          .sort((a, b) => b.count - a.count)
          .slice(0, 25),
      };
    });
    await page.close();
    const deltas = Number(run.deltas ?? 0);
    console.log(
      `STREAM-OFFSCREEN ${JSON.stringify({ ...mounted, deltas, frames: run.frames, reads: probe.reads, offscreen: probe.offscreen, walks: probe.walks })}`,
    );
    for (const site of probe.sites) console.log(`  STREAM-OFFSCREEN site ${site.count} ${site.at}`);
    expect(deltas).toBeGreaterThan(100);
    // The rows out of view are mounted (history above the view): the reads below would have something to read.
    expect(mounted.mounted).toBeGreaterThan(mounted.inView);
    // Per streamed chunk: a turn's own structural passes (its start, its end folding) may read or query once;
    // a chunk may not.
    const perChunk = (count: number) => Math.round((count / deltas) * 100) / 100;
    expect(perChunk(probe.offscreen), "layout or style reads of a mounted row out of view, per chunk").toBeLessThan(
      0.1,
    );
    expect(perChunk(probe.walks), "queries over every mounted row, per chunk").toBeLessThan(0.1);
  });
});
