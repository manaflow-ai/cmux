// The list contract: a list (a collection whose length grows with the person's data) costs the same
// at 1,000 rows and at 10,000. Leo, 2026-11-18: "we draw the visible area, right? Like, that's what
// we're supposed to do ... there are so many places where I'm pretty sure we're just, like, drawing
// the whole list. And we need to be able to, like, guard against that." For every registered list
// (test/list-contract/<name>.fixture.tsx, listFixture.ts) at N rows:
//   rule 1  mounted rows <= the rows in the viewport + the declared overscan each side + `keep`;
//           mounted rows, DOM nodes under the scroller and observed elements flat in N (10 percent).
//           `content-visibility: auto` does not count: its rows are still mounted.
//   rule 2  per event (one item change, a one-row scroll, a hover, a select, a clock tick, a 20 px
//           width change) no row whose DOM did not change rendered, and at most: change 1, scroll 0,
//           hover 1, select 1 row; width at most once per mounted row. Renders come from React's
//           commit hook (commitRenders.ts), charged to the row whose DOM the fiber is in, so a list
//           needs no counters of its own.
//   rule 3  per event, flat in N: layout reads on the main thread (getBoundingClientRect, offset*,
//           client*, scroll*, getComputedStyle) and, on Chromium, elements restyled and objects laid
//           out (the trace's UpdateLayoutTree and Layout).
// Violations a list has today are in test/list-contract/baseline.json; that file only shrinks.
import type { Browser, Page } from "playwright";
import type { ListEvent } from "../list-contract/listFixture";
import type { ListPage } from "../browser/list-contract.harness";
import { installRowRenderCounter, type RowRenderCount, type RowRenderCounter } from "./commitRenders";

export const LIST_SIZES = [1_000, 10_000] as const;
export const LIST_EVENTS: readonly ListEvent[] = ["change", "scroll", "hover", "select", "tick", "width"];
/// Rows a change of each kind may render (rows whose DOM changed); width: once per mounted row.
const RENDER_LIMIT: Record<Exclude<ListEvent, "width">, number> = {
  change: 1,
  scroll: 0,
  hover: 1,
  select: 1,
  tick: Number.POSITIVE_INFINITY,
};
const NARROWER_PX = 20;

/// What the probes saw over one event.
export type EventCount = RowRenderCount & {
  /// Layout reads on the main thread.
  reads: number;
};
export type EventMeasure = EventCount & {
  /// Chromium: elements restyled, layouts, and objects laid out over the event.
  restyled?: number;
  layouts?: number;
  laidOut?: number;
};
export type ListMeasure = {
  list: string;
  engine: string;
  n: number;
  mounted: number;
  visible: number;
  /// What rule 1 allows: visible + overscan each side + keep.
  allowed: number;
  nodes: number;
  /// Elements under a ResizeObserver or IntersectionObserver.
  observed: number;
  events: Partial<Record<ListEvent, EventMeasure | { skipped: string }>>;
};

type Probe = {
  begin(rows: string, scroller: string): void;
  end(): EventCount;
  observed(): number;
};

/**
 * Installed before the page's scripts (page.addInitScript), after installRowRenderCounter
 * (commitRenders.ts, the row renders): counters for layout reads and observed elements.
 * Self-contained: Playwright serializes it into the page.
 */
export function installListProbes() {
  let counting = false;
  let reads = 0;

  // Layout reads: each of these lays out a dirty tree before it answers.
  const count = () => {
    if (counting) reads++;
  };
  for (const name of ["getBoundingClientRect", "getClientRects"] as const) {
    const original = Element.prototype[name] as (this: Element) => unknown;
    Element.prototype[name] = function (this: Element) {
      count();
      return original.call(this);
    } as never;
  }
  const getters: Array<[object, string[]]> = [
    [HTMLElement.prototype, ["offsetTop", "offsetLeft", "offsetWidth", "offsetHeight", "offsetParent"]],
    [
      Element.prototype,
      [
        "clientTop",
        "clientLeft",
        "clientWidth",
        "clientHeight",
        "scrollTop",
        "scrollLeft",
        "scrollWidth",
        "scrollHeight",
      ],
    ],
  ];
  for (const [proto, names] of getters)
    for (const name of names) {
      const descriptor = Object.getOwnPropertyDescriptor(proto, name);
      if (!descriptor?.get) continue;
      const get = descriptor.get;
      Object.defineProperty(proto, name, {
        ...descriptor,
        get() {
          count();
          return get.call(this);
        },
      });
    }
  const computed = window.getComputedStyle;
  window.getComputedStyle = function (this: Window, ...args: Parameters<typeof computed>) {
    count();
    return computed.apply(this, args);
  };

  // Observed elements, live: observe adds, unobserve and disconnect remove.
  const watched = new Map<object, Set<Element>>();
  for (const Observer of [window.ResizeObserver, window.IntersectionObserver]) {
    if (!Observer) continue;
    const proto = Observer.prototype as {
      observe(target: Element, options?: unknown): void;
      unobserve(target: Element): void;
      disconnect(): void;
    };
    const { observe, unobserve, disconnect } = proto;
    proto.observe = function (target, options) {
      (watched.get(this) ?? watched.set(this, new Set()).get(this)!).add(target);
      return observe.call(this, target, options);
    };
    proto.unobserve = function (target) {
      watched.get(this)?.delete(target);
      return unobserve.call(this, target);
    };
    proto.disconnect = function () {
      watched.delete(this);
      return disconnect.call(this);
    };
  }

  const renders = (globalThis as unknown as { __cmuxRowRenders: RowRenderCounter }).__cmuxRowRenders;
  const probe: Probe = {
    begin(rows, scrollerSelector) {
      const scroller = document.querySelector(scrollerSelector);
      if (scroller) renders.begin(scroller, rows);
      reads = 0;
      counting = true;
    },
    end() {
      counting = false;
      return { ...renders.end(), reads };
    },
    observed() {
      let total = 0;
      for (const targets of watched.values()) total += targets.size;
      return total;
    },
  };
  (window as unknown as { __listProbe: Probe }).__listProbe = probe;
}

type TraceEvent = { name: string; ph: string; ts: number; pid: number; tid: number; args?: any };

/// Elements restyled, layouts and objects laid out on the renderer's main thread over `run`.
async function traceCounts(browser: Browser, page: Page, run: () => Promise<void>) {
  await browser.startTracing(page, { categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] });
  await run();
  const { traceEvents } = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: TraceEvent[] };
  const mains = new Set(
    traceEvents
      .filter((event) => event.ph === "M" && event.name === "thread_name" && event.args?.name === "CrRendererMain")
      .map((event) => `${event.pid}:${event.tid}`),
  );
  let restyled = 0;
  let layouts = 0;
  let laidOut = 0;
  for (const event of traceEvents) {
    if (!mains.has(`${event.pid}:${event.tid}`)) continue;
    if (event.name === "UpdateLayoutTree" && (event.ph === "X" || event.ph === "E"))
      restyled += Number(event.args?.elementCount ?? event.args?.data?.elementCount ?? 0);
    if (event.name === "Layout" && (event.ph === "X" || event.ph === "B")) {
      layouts++;
      laidOut += Number(event.args?.beginData?.dirtyObjects ?? 0);
    }
  }
  return { restyled, layouts, laidOut };
}

const settle = (page: Page) =>
  page.evaluate(
    () =>
      new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 50)))),
      ),
  );

/**
 * Mounts list `name` at `n` rows on `base` (a server of webviews/ whose
 * /test/browser/list-contract.html is the harness), then measures each event. Traces on Chromium.
 */
export async function measureList(browser: Browser, base: string, name: string, n: number): Promise<ListMeasure> {
  const engine = browser.browserType().name();
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  try {
    await page.addInitScript(installRowRenderCounter);
    await page.addInitScript(installListProbes);
    await page.goto(`${base}/test/browser/list-contract.html?list=${name}&n=${n}`);
    await page.waitForFunction(() => "__list" in window, null, { timeout: 60_000 });
    const meta = await page.evaluate(async () => {
      const list = (window as unknown as { __list: ListPage }).__list;
      await list.ready;
      return list.meta;
    });
    // Mounted once the rows are there and their count held for five frames (a list that reads its
    // data, or measures and then windows, settles over a few).
    await page.waitForFunction(
      ({ scroller, rows }) =>
        new Promise<boolean>((resolve) => {
          const count = () => document.querySelector(scroller)?.querySelectorAll(rows).length ?? 0;
          const first = count();
          let frames = 0;
          const next = () => {
            if (count() !== first) resolve(false);
            else if (++frames === 5) resolve(first > 0);
            else requestAnimationFrame(next);
          };
          requestAnimationFrame(next);
        }),
      meta,
      { timeout: 60_000 },
    );
    await settle(page);

    /// The rows in view now: their count, the middle one's index among the mounted rows and its
    /// center, and a row's height.
    const view = () =>
      page.evaluate(({ scroller, rows }) => {
        const box = document.querySelector(scroller)!;
        const clip = box.getBoundingClientRect();
        const root = document.getElementById("root")!.getBoundingClientRect();
        const top = Math.max(clip.top, root.top, 0);
        const bottom = Math.min(clip.bottom, root.bottom, innerHeight);
        const all = [...box.querySelectorAll(rows)];
        const inView = all
          .map((row, index) => ({ index, rect: row.getBoundingClientRect() }))
          .filter(({ rect }) => rect.height > 0 && rect.bottom > top && rect.top < bottom);
        const middle = inView[Math.floor(inView.length / 2)];
        return {
          mounted: all.length,
          visible: inView.length,
          nodes: box.getElementsByTagName("*").length,
          middle: middle?.index ?? 0,
          center: middle
            ? { x: middle.rect.left + middle.rect.width / 2, y: middle.rect.top + middle.rect.height / 2 }
            : { x: 0, y: 0 },
          pitch: inView[0]?.rect.height ?? 20,
        };
      }, meta);
    const shape = await view();
    const overscanRows = meta.overscan?.rows ?? Math.ceil((meta.overscan?.viewports ?? 1) * shape.visible);
    const measure: ListMeasure = {
      list: name,
      engine,
      n,
      mounted: shape.mounted,
      visible: shape.visible,
      allowed: shape.visible + 2 * overscanRows + (meta.keep ?? 2),
      nodes: shape.nodes,
      observed: 0,
      events: {},
    };

    const actions: Record<ListEvent, (at: Awaited<ReturnType<typeof view>>) => Promise<unknown>> = {
      change: (at) =>
        page.evaluate((index) => (window as unknown as { __list: ListPage }).__list.change(index), at.middle),
      scroll: (at) =>
        page.evaluate(
          ({ scroller, pitch }) => {
            document.querySelector(scroller)!.scrollTop += pitch;
          },
          { scroller: meta.scroller, pitch: at.pitch },
        ),
      hover: (at) => page.mouse.move(at.center.x, at.center.y),
      select: (at) =>
        page.evaluate((index) => (window as unknown as { __list: ListPage }).__list.select(index), at.middle),
      tick: () => page.evaluate(() => (window as unknown as { __list: ListPage }).__list.tick()),
      width: () =>
        page.evaluate((px) => (window as unknown as { __list: ListPage }).__list.width(px), 420 - NARROWER_PX),
    };
    for (const event of LIST_EVENTS) {
      const skipped = event === "change" && !meta.canChange ? "the fixture has no change()" : meta.skip?.[event];
      if (skipped) {
        measure.events[event] = { skipped };
        continue;
      }
      // The pointer starts off the list, so a hover enters a row from outside.
      await page.mouse.move(890, 890);
      await settle(page);
      const at = await view();
      await page.evaluate(
        (meta) => (window as unknown as { __listProbe: Probe }).__listProbe.begin(meta.rows, meta.scroller),
        meta,
      );
      const run = async () => {
        await actions[event](at);
        await settle(page);
      };
      const traced = engine === "chromium" ? await traceCounts(browser, page, run) : (await run(), undefined);
      const counted = await page.evaluate(() => (window as unknown as { __listProbe: Probe }).__listProbe.end());
      measure.events[event] = { ...counted, ...traced };
    }
    // Read at rest, after every event: a list may attach its observers over its first frames.
    measure.observed = await page.evaluate(() => (window as unknown as { __listProbe: Probe }).__listProbe.observed());
    return measure;
  } finally {
    await page.close();
  }
}

/// Within 10 percent and `slack` of the small list's figure.
const flat = (small: number, big: number, slack: number) => big <= small * 1.1 + slack;

/**
 * The contract's violations for one list on one engine, measured at the sizes in LIST_SIZES (small
 * first): stable ids, so the baseline can name them, each with what was measured.
 */
export function listViolations([small, big]: [ListMeasure, ListMeasure]): Map<string, string> {
  const found = new Map<string, string>();
  const at = (measure: ListMeasure) => `at N=${measure.n.toLocaleString("en-US")}`;
  for (const measure of [small, big])
    if (measure.mounted > measure.allowed && !found.has("mounted"))
      found.set(
        "mounted",
        `${measure.mounted} rows mounted ${at(measure)}, ${measure.visible} in view: at most ${measure.allowed} (the view, its overscan each side and ${measure.allowed - measure.visible} more)`,
      );
  const grows = (id: string, what: string, a: number, b: number, slack: number) => {
    if (!flat(a, b, slack)) found.set(id, `${what} grow with N: ${a} ${at(small)}, ${b} ${at(big)}`);
  };
  grows("flat:mounted", "mounted rows", small.mounted, big.mounted, 2);
  grows("flat:nodes", "DOM nodes under the scroller", small.nodes, big.nodes, 30);
  grows("flat:observed", "observed elements", small.observed, big.observed, 2);
  for (const event of LIST_EVENTS) {
    const a = small.events[event];
    const b = big.events[event];
    if (!a || !b || "skipped" in a || "skipped" in b) continue;
    for (const measure of [b, a]) {
      const limit = event === "width" ? Number.POSITIVE_INFINITY : RENDER_LIMIT[event];
      const tooMany = measure.wasted > 0 || measure.rerendered > limit || (event === "width" && measure.maxRenders > 1);
      if (tooMany && !found.has(`renders:${event}`))
        found.set(
          `renders:${event}`,
          `one ${event} rendered ${measure.rerendered} mounted rows (${measure.wasted} with no change to their DOM, at most ${measure.maxRenders} times each) ${at(measure === a ? small : big)}`,
        );
    }
    grows(`flat:reads:${event}`, `layout reads per ${event}`, a.reads, b.reads, 4);
    if (a.restyled !== undefined && b.restyled !== undefined)
      grows(`flat:restyle:${event}`, `elements restyled per ${event}`, a.restyled, b.restyled, 40);
    if (a.laidOut !== undefined && b.laidOut !== undefined)
      grows(`flat:layout:${event}`, `objects laid out per ${event}`, a.laidOut, b.laidOut, 40);
  }
  return found;
}

/// One line per list and size, for the report and a PR's before/after numbers.
export function listReport(measure: ListMeasure): string {
  const events = LIST_EVENTS.map((event) => {
    const each = measure.events[event];
    if (!each) return `${event}=-`;
    if ("skipped" in each) return `${event}=skip`;
    const trace = each.restyled === undefined ? "" : `/${each.restyled}st/${each.laidOut}lo`;
    return `${event}=${each.rerendered}r(${each.wasted}w)/${each.reads}rd${trace}`;
  });
  return `LIST-CONTRACT ${measure.list} ${measure.engine} N=${measure.n} mounted=${measure.mounted} visible=${measure.visible} allowed=${measure.allowed} nodes=${measure.nodes} observed=${measure.observed} ${events.join(" ")}`;
}
