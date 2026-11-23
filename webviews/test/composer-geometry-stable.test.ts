// cmux-web-test-timeout: 240
// The composer's geometry holds still where Leo looks, frame by frame (Leo, 2026-11-22):
//   "the buttons for send attach all that doesnt follow/simply stick with
//    teh bottom of the composer. plus, the caret gets shot down past the composer as it goes."
//   "deleting attachments make the composer AND the text jump in a layout shift instead of a
//    smooth motion."
//
// Typing: a draft typed key by key until it wraps, then Shift-Enter lines until the field reaches
// its cap and scrolls. Every painted frame (test/support/paintedFrames.ts), at every height and
// through every growth motion: the + button, the mic and Send sit at one constant offset from the
// composer box's bottom edge (within 0.5 px), and the caret (the field's drawn bar,
// composer/inlineCaret.ts, else the selection's rect) is inside the field's visible text box (the
// .acpmux-md-field box less its padding).
//
// Attachments: a screenshot pasted into the text and then removed with its ×. Every painted frame:
// the text's first line moves no more than the box's own top edge does (the text never jumps inside
// the box), and the box's height changes over several frames, never in one step. In Chromium, the
// layout-shift entries are counted and summed; a source in the composer that moves more than a
// smooth step in one entry fails it. WebKit reports no layout shifts, so there the frames decide.
//
// Prints one numbers table per run (before/after quotes). Real Chromium and WebKit (the app's
// engine) from Playwright; CI fails the file when one cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-geometry-stable.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import {
  COMPOSER_EDITOR,
  COMPOSER_MD,
  COMPOSER_MD_FIELD,
  PLUS_PICKER,
} from "../src/agent-session/acpmux/composerSelectors";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Edge = { top: number; bottom: number };
/** One painted frame of the composer. */
type Sample = {
  /** performance.now() at the frame's callback. */
  at: number;
  boxTop: number;
  boxBottom: number;
  boxHeight: number;
  /** The field's visible text box: its border box less border and padding. */
  visible: Edge;
  capped: boolean;
  /** Each control's bottom edge, null when it is not drawn this frame. */
  parts: Record<string, number | null>;
  caret: (Edge & { source: string }) | null;
  /** The top of the draft's first line of text (never an attachment's label). */
  textTop: number | null;
  chips: number;
};
type Shift = { value: number; hadRecentInput: boolean; maxMove: number; mover?: string };
type Probe = { samples: Sample[]; stable: number; stop: () => void; shifts: Shift[]; observer?: PerformanceObserver };
type ProbeWindow = Window & { __geometry?: Probe; cmuxAcpmuxComposer?: (settings: Record<string, unknown>) => void };
type Selectors = { box: string; field: string; md: string; parts: Record<string, string> };

type Row = {
  scenario: string;
  frames: number;
  bottomSpread: string;
  caretOut: string;
  shifts: string;
  maxStep: string;
  textJump: string;
};

await requireBrowserLane("composer-geometry-stable.test.ts", async () => {
  setDefaultTimeout(240_000);
  const LONG =
    "Please refactor the fetch helper so that every GET retries with exponential backoff and jitter, " +
    "keep POST requests idempotent behind a policy flag, and add tests for the 429 and 503 paths";
  const WIDTH = 420;
  const engines: [string, BrowserType][] = [];
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    try {
      await (await engine.launch({ headless: true, timeout: 30_000 })).close();
      engines.push([name, engine]);
    } catch {
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-geometry-stable: ${name} did not launch`);
      console.warn(`composer-geometry-stable: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (!engines.length) {
    describe.skip("composer geometry", () => test("browsers", () => {}));
    return;
  }

  const SELECTORS: Selectors = {
    box: ".acpmux-composer-box",
    field: COMPOSER_MD_FIELD,
    md: COMPOSER_MD,
    parts: {
      plus: PLUS_PICKER,
      mic: ".acpmux-composer-box .acpmux-fit-mic",
      send: ".acpmux-composer-box .acpmux-composer-actions .acpmux-send",
    },
  };

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const rows: Row[] = [];
  const stageURL = (width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer", { variant: "idle", frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.composer", {
      browser: browsers.get("chromium") ?? browsers.get("webkit"),
      params: { variant: "idle" },
    });
  });
  afterAll(async () => {
    const head: Row = {
      scenario: "scenario",
      frames: 0,
      bottomSpread: "bottom-offset spread px (plus/mic/send)",
      caretOut: "caret-out frames / max px",
      shifts: "layout-shift n / sum / max move px",
      maxStep: "max 1-frame height step px / total px",
      textJump: "max text jump px",
    };
    const cells = (row: Row) => [
      row.scenario,
      row === head ? "frames" : String(row.frames),
      row.bottomSpread,
      row.caretOut,
      row.shifts,
      row.maxStep,
      row.textJump,
    ];
    const all = [head, ...rows].map(cells);
    const widths = all[0]!.map((_, column) => Math.max(...all.map((line) => line[column]!.length)));
    const table = all.map((line) => `| ${line.map((cell, column) => cell.padEnd(widths[column]!)).join(" | ")} |`);
    table.splice(1, 0, `|${widths.map((width) => "-".repeat(width + 2)).join("|")}|`);
    console.log(`\ncomposer-geometry-stable numbers:\n${table.join("\n")}\n`);
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** Runs in the page: samples the composer after every painted frame until stopped. */
  function startProbe(selectors: Selectors) {
    const box = document.querySelector<HTMLElement>(selectors.box)!;
    const field = document.querySelector<HTMLElement>(selectors.field)!;
    const md = document.querySelector<HTMLElement>(selectors.md)!;
    const probe: Probe = { samples: [], stable: 0, stop: () => {}, shifts: [] };
    (window as ProbeWindow).__geometry = probe;
    const start = performance.now();
    if (PerformanceObserver.supportedEntryTypes?.includes("layout-shift")) {
      type Source = { node?: Node | null; previousRect: DOMRectReadOnly; currentRect: DOMRectReadOnly };
      type Entry = PerformanceEntry & { value: number; hadRecentInput: boolean; sources?: Source[] };
      const take = (entries: PerformanceEntryList) => {
        for (const entry of entries as Entry[]) {
          if (entry.startTime < start) continue;
          let maxMove = 0;
          // The node that moved most, named in the failure (its tag and classes, its rects).
          let mover: string | undefined;
          for (const source of entry.sources ?? []) {
            if (!source.node || !box.contains(source.node)) continue;
            const move = Math.max(
              Math.abs(source.currentRect.y - source.previousRect.y),
              Math.abs(source.currentRect.x - source.previousRect.x),
            );
            if (move <= maxMove) continue;
            maxMove = move;
            const element = source.node instanceof Element ? source.node : source.node.parentElement;
            const name = element ? `${element.tagName.toLowerCase()}.${[...element.classList].join(".")}` : "text";
            const rect = (each: DOMRectReadOnly) =>
              `${each.x.toFixed(1)},${each.y.toFixed(1)} ${each.width.toFixed(1)}x${each.height.toFixed(1)}`;
            mover = `${name} ${rect(source.previousRect)} -> ${rect(source.currentRect)} at ${entry.startTime.toFixed(1)} ms`;
          }
          probe.shifts.push({
            value: entry.value,
            hadRecentInput: entry.hadRecentInput,
            maxMove,
            ...(mover ? { mover } : {}),
          });
        }
      };
      const observer = new PerformanceObserver((list) => take(list.getEntries()));
      observer.observe({ type: "layout-shift", buffered: true });
      probe.observer = observer;
    }
    const firstTextTop = (): number | null => {
      const walker = document.createTreeWalker(md, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode: (node) =>
          node.nodeType === 1
            ? (node as Element).hasAttribute("data-inline-attachment")
              ? NodeFilter.FILTER_REJECT
              : NodeFilter.FILTER_SKIP
            : NodeFilter.FILTER_ACCEPT,
      });
      const range = document.createRange();
      for (let text = walker.nextNode(); text; text = walker.nextNode()) {
        if (!text.textContent?.trim()) continue;
        range.selectNodeContents(text);
        const rect = [...range.getClientRects()].find((each) => each.height > 0);
        if (rect) return rect.top;
      }
      return null;
    };
    // The caret: the field's drawn bar on an attachment's line; else the lower of the selection's
    // rect and the draft's last glyph (every edit here is at the draft's end, and WebKit can report
    // a paragraph's end as its start).
    const caret = (): Sample["caret"] => {
      if (!md.contains(document.activeElement) && document.activeElement !== md) return null;
      const drawn = field.querySelector<HTMLElement>(".acpmux-md-caret:not([hidden])");
      const bar = drawn?.getBoundingClientRect();
      if (drawn && bar && bar.height > 0 && getComputedStyle(drawn).display !== "none")
        return { top: bar.top, bottom: bar.bottom, source: "drawn" };
      const candidates: (Edge & { source: string })[] = [];
      const selection = getSelection();
      const range = selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : undefined;
      if (range && range.collapsed && md.contains(range.endContainer)) {
        let rect = [...range.getClientRects()].find((each) => each.height > 0);
        if (!rect && range.endContainer.nodeType === 1) {
          const parent = range.endContainer as Element;
          const near = parent.childNodes[range.endOffset] ?? parent.childNodes[range.endOffset - 1];
          const own = near instanceof Element ? near.getBoundingClientRect() : parent.getBoundingClientRect();
          if (own.height > 0) rect = own;
        }
        if (rect) candidates.push({ top: rect.top, bottom: rect.bottom, source: "selection" });
      }
      const texts: Text[] = [];
      const walker = document.createTreeWalker(md, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode())
        if ((node as Text).length && !node.parentElement?.closest("[data-inline-attachment]")) texts.push(node as Text);
      const last = texts.at(-1);
      if (last) {
        const end = document.createRange();
        end.setStart(last, last.length - 1);
        end.setEnd(last, last.length);
        const rect = [...end.getClientRects()].filter((each) => each.height > 0).at(-1);
        if (rect) candidates.push({ top: rect.top, bottom: rect.bottom, source: "glyph" });
      }
      return candidates.sort((a, b) => b.bottom - a.bottom)[0] ?? null;
    };
    probe.stop = window.cmuxAfterPaint(() => {
      const outer = box.getBoundingClientRect();
      const own = field.getBoundingClientRect();
      const style = getComputedStyle(field);
      const parts: Record<string, number | null> = {};
      for (const [name, selector] of Object.entries(selectors.parts)) {
        const rect = document.querySelector(selector)?.getBoundingClientRect();
        parts[name] = rect && rect.width > 0 && rect.height > 0 ? rect.bottom : null;
      }
      const sample: Sample = {
        boxTop: outer.top,
        boxBottom: outer.bottom,
        boxHeight: outer.height,
        at: performance.now(),
        visible: {
          top: own.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop),
          bottom: own.bottom - parseFloat(style.borderBottomWidth) - parseFloat(style.paddingBottom),
        },
        capped: field.scrollHeight > field.clientHeight + 1,
        parts,
        caret: caret(),
        textTop: firstTextTop(),
        chips: md.querySelectorAll("[data-inline-attachment]").length,
      };
      const previous = probe.samples.at(-1);
      probe.stable =
        previous && Math.abs(previous.boxHeight - sample.boxHeight) < 0.01 && previous.textTop === sample.textTop
          ? probe.stable + 1
          : 0;
      probe.samples.push(sample);
    });
  }

  const start = (page: Page) => page.evaluate(startProbe, SELECTORS);
  /** Waits until the box has held its height (and the text its place) for `frames` painted frames. */
  const settled = (page: Page, frames = 10) =>
    page.waitForFunction((frames) => ((window as ProbeWindow).__geometry?.stable ?? 0) >= frames, frames, {
      timeout: 20_000,
    });
  const stop = (page: Page) =>
    page.evaluate(() => {
      const probe = (window as ProbeWindow).__geometry!;
      probe.stop();
      if (probe.observer) {
        const records = probe.observer.takeRecords() as (PerformanceEntry & {
          value: number;
          hadRecentInput: boolean;
        })[];
        for (const entry of records)
          probe.shifts.push({ value: entry.value, hadRecentInput: entry.hadRecentInput, maxMove: 0 });
        probe.observer.disconnect();
      }
      return { samples: probe.samples, shifts: probe.shifts, observed: !!probe.observer };
    });
  /** A key, then the frame it paints. */
  const key = async (page: Page, press: () => Promise<void>) => {
    await press();
    return page.evaluate(
      (selector) =>
        window.cmuxPaintFrame().then(() => {
          const field = document.querySelector<HTMLElement>(selector)!;
          return field.scrollHeight > field.clientHeight + 1;
        }),
      COMPOSER_MD_FIELD,
    );
  };

  async function open(engine: string): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: WIDTH, height: 900 } });
    await installPaintedFrames(page);
    await page.goto(stageURL(WIDTH));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.locator(COMPOSER_EDITOR).waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.click(COMPOSER_EDITOR);
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    return page;
  }

  const fmt = (value: number) => (Number.isFinite(value) ? value.toFixed(1) : "-");

  /** Each control's spread of bottom offsets from the box's bottom edge over the frames. */
  function bottomSpreads(samples: Sample[]) {
    const spreads: Record<string, { spread: number; min: number; max: number; frames: number }> = {};
    for (const name of Object.keys(SELECTORS.parts)) {
      const offsets = samples.flatMap((sample) =>
        sample.parts[name] === null ? [] : [sample.boxBottom - sample.parts[name]!],
      );
      const min = Math.min(...offsets);
      const max = Math.max(...offsets);
      spreads[name] = { spread: offsets.length ? max - min : 0, min, max, frames: offsets.length };
    }
    return spreads;
  }

  /** The caret's frames outside the field's visible text box, and its farthest. */
  function caretOutside(samples: Sample[]) {
    let frames = 0;
    let worst = 0;
    let unknown = 0;
    let first: string | undefined;
    for (const [index, sample] of samples.entries()) {
      if (!sample.caret) {
        unknown++;
        continue;
      }
      const past = Math.max(sample.visible.top - sample.caret.top, sample.caret.bottom - sample.visible.bottom);
      // Half a pixel more: WebKit's selection rect runs a subpixel past the line box it sits in.
      if (past > 1) {
        frames++;
        first ??= `frame ${index}: ${sample.caret.source} caret ${fmt(sample.caret.top)}..${fmt(sample.caret.bottom)} in ${fmt(sample.visible.top)}..${fmt(sample.visible.bottom)} (box ${fmt(sample.boxHeight)} px${sample.capped ? ", capped" : ""})`;
      }
      worst = Math.max(worst, past);
    }
    return { frames, worst, unknown, first };
  }

  /** The box's height steps and the text's moves beyond the box's own top-edge move, frame to frame. */
  function motion(samples: Sample[]) {
    let maxStep = 0;
    let steps = 0;
    let textJump = 0;
    let jumpAt: string | undefined;
    for (let index = 1; index < samples.length; index++) {
      const before = samples[index - 1]!;
      const after = samples[index]!;
      const step = Math.abs(after.boxHeight - before.boxHeight);
      if (step > 0.25) steps++;
      maxStep = Math.max(maxStep, step);
      // A line the top edge covers in either frame is not drawn there: a growth draws every line in
      // its final place and uncovers the top one as the edge rises (fieldGrowth.ts), so only a line
      // shown in both frames can jump.
      const shown = (sample: Sample) => sample.textTop !== null && sample.textTop >= sample.visible.top - 0.5;
      if (shown(before) && shown(after)) {
        const excess = Math.abs(after.textTop - before.textTop) - Math.abs(after.boxTop - before.boxTop);
        if (excess > textJump) {
          textJump = excess;
          jumpAt = `frame ${index}: text ${fmt(before.textTop)}->${fmt(after.textTop)}, box top ${fmt(before.boxTop)}->${fmt(after.boxTop)}, height ${fmt(before.boxHeight)}->${fmt(after.boxHeight)}`;
        }
      }
    }
    const total = Math.abs(samples.at(-1)!.boxHeight - samples[0]!.boxHeight);
    return { maxStep, steps, total, textJump: Math.max(0, textJump), jumpAt };
  }

  for (const [engine] of engines) {
    test(`${engine}: typing to the cap keeps +, mic and Send on the box's bottom edge and the caret in the field`, async () => {
      const page = await open(engine);
      try {
        await start(page);
        // Key by key until it wraps (several lines at this width), then Shift-Enter lines until the
        // field scrolls, three lines past it; every height is also held until it settles.
        for (const char of LONG) await key(page, () => page.keyboard.type(char));
        await settled(page);
        let capped = false;
        let past = 0;
        for (let line = 1; line <= 40 && past < 3; line++) {
          await key(page, () => page.keyboard.press("Shift+Enter"));
          for (const char of `line ${line} of the plan`) capped = await key(page, () => page.keyboard.type(char));
          await settled(page, 6);
          if (capped) past++;
        }
        const { samples } = await stop(page);
        const spreads = bottomSpreads(samples);
        const out = caretOutside(samples);
        const heights = samples.map((sample) => sample.boxHeight);
        const label = `${engine} type to cap`;
        rows.push({
          scenario: label,
          frames: samples.length,
          bottomSpread: Object.values(spreads)
            .map((each) => (each.frames ? fmt(each.spread) : "absent"))
            .join(" / "),
          caretOut: `${out.frames} / ${fmt(out.worst)}`,
          shifts: "-",
          maxStep: `${fmt(motion(samples).maxStep)} / ${fmt(Math.max(...heights) - Math.min(...heights))}`,
          textJump: "-",
        });
        console.log(
          `composer-geometry-stable ${label}: box ${fmt(Math.min(...heights))}..${fmt(Math.max(...heights))} px, ` +
            `offsets ${JSON.stringify(Object.fromEntries(Object.entries(spreads).map(([name, each]) => [name, `${fmt(each.min)}..${fmt(each.max)}`])))}, ` +
            `caret unknown in ${out.unknown} frames${out.first ? `; first outside: ${out.first}` : ""}`,
        );
        expect(capped, `${label}: the field reached its cap and scrolls`).toBe(true);
        expect(spreads.plus!.frames, `${label}: the + button is drawn`).toBeGreaterThan(0);
        expect(spreads.send!.frames + spreads.mic!.frames, `${label}: Send or the mic is drawn`).toBeGreaterThan(0);
        for (const [name, each] of Object.entries(spreads))
          expect(
            each.spread,
            `${label}: ${name}'s offset from the box's bottom edge, ${fmt(each.min)}..${fmt(each.max)} px`,
          ).toBeLessThanOrEqual(0.5);
        expect(out.frames, `${label}: frames with the caret outside the field's text box (${out.first ?? ""})`).toBe(0);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: adding and removing an attachment moves the box smoothly and never jumps the text`, async () => {
      const page = await open(engine);
      try {
        await page.keyboard.type("Compare this screenshot with the last one ");
        await page.evaluate(() => (window as ProbeWindow).cmuxAcpmuxComposer?.({ attachmentView: "inline" }));
        const phases: { phase: string; samples: Sample[]; shifts: Shift[]; observed: boolean }[] = [];
        // The paste the gallery's own plays make (composer.gallery.ts pasteComparison).
        await start(page);
        await settled(page, 4);
        await page.evaluate(async (md) => {
          const canvas = document.createElement("canvas");
          canvas.width = 320;
          canvas.height = 180;
          const drawing = canvas.getContext("2d")!;
          drawing.fillStyle = "#5783b5";
          drawing.fillRect(0, 0, 320, 180);
          const blob = await new Promise<Blob>((resolve) => canvas.toBlob((value) => resolve(value!), "image/png"));
          const paste = new Event("paste", { bubbles: true, cancelable: true });
          Object.defineProperty(paste, "clipboardData", {
            value: {
              files: [new File([blob], "comparison.png", { type: "image/png" })],
              types: ["Files"],
              getData: () => "",
            },
          });
          document.querySelector(md)!.dispatchEvent(paste);
        }, COMPOSER_MD);
        await page.waitForFunction(
          (md) => {
            const image = document.querySelector<HTMLImageElement>(`${md} [data-inline-attachment] img`);
            return !!image && image.complete && image.naturalWidth > 0;
          },
          COMPOSER_MD,
          { timeout: 30_000 },
        );
        await settled(page, 12);
        phases.push({ phase: "add", ...(await stop(page)) });

        await start(page);
        await settled(page, 4);
        const chip = page.locator(`${COMPOSER_MD} [data-inline-attachment]`).first();
        await chip.hover();
        await chip.locator(".acpmux-attachment-remove").click();
        await page.waitForFunction((md) => !document.querySelector(`${md} [data-inline-attachment]`), COMPOSER_MD, {
          timeout: 10_000,
        });
        await settled(page, 12);
        phases.push({ phase: "remove", ...(await stop(page)) });

        // Every phase is measured and printed before any check fails, so both numbers reach the table.
        const failures: string[] = [];
        const fail = (ok: boolean, message: string) => ok || failures.push(message);
        for (const { phase, samples, shifts, observed } of phases) {
          const label = `${engine} attachment ${phase}`;
          const moved = motion(samples);
          const sum = shifts.reduce((total, each) => total + each.value, 0);
          const shiftMove = Math.max(0, ...shifts.map((each) => each.maxMove));
          rows.push({
            scenario: label,
            frames: samples.length,
            bottomSpread: Object.values(bottomSpreads(samples))
              .map((each) => (each.frames ? fmt(each.spread) : "absent"))
              .join(" / "),
            caretOut: "-",
            shifts: observed ? `${shifts.length} / ${sum.toFixed(4)} / ${fmt(shiftMove)}` : "n/a (webkit)",
            maxStep: `${fmt(moved.maxStep)} / ${fmt(moved.total)}`,
            textJump: fmt(moved.textJump),
          });
          const heights = samples
            .map((sample) => fmt(sample.boxHeight))
            .filter((height, index, all) => index === 0 || height !== all[index - 1]);
          if (process.env.GEOMETRY_TIMES)
            console.log(
              `${label} frames: ${samples.map((each) => `${each.at.toFixed(1)}:${fmt(each.boxHeight)}`).join(" ")}`,
            );
          console.log(
            `composer-geometry-stable ${label}: ${moved.steps} frames of height change, chips ${samples[0]!.chips}->${samples.at(-1)!.chips}, heights ${heights.join(" ")}` +
              `${moved.jumpAt ? `; worst text move ${moved.jumpAt}` : ""}`,
          );
          fail(
            samples.at(-1)!.chips === (phase === "add" ? 1 : 0),
            `${label}: the attachment is ${phase === "add" ? "not in" : "still in"} the text`,
          );
          // The text never moves more in one frame than the box's top edge does.
          fail(
            moved.textJump <= 1,
            `${label}: text moved ${fmt(moved.textJump)} px past the box's own edge (${moved.jumpAt ?? ""})`,
          );
          // A height change is a motion over frames, never one step: no frame takes half of it.
          const smooth = Math.max(4, 0.5 * moved.total);
          if (moved.total > 4) {
            fail(moved.steps >= 3, `${label}: the box's ${fmt(moved.total)} px change spans ${moved.steps} frames`);
            fail(
              moved.maxStep <= smooth,
              `${label}: the box moved ${fmt(moved.maxStep)} px of its ${fmt(moved.total)} px change in one frame (heights ${heights.join(" ")})`,
            );
          }
          // Chromium's own layout-shift record: no part of the composer jumps in one frame.
          if (observed)
            fail(
              shiftMove <= smooth,
              `${label}: a layout shift moved part of the composer ${fmt(shiftMove)} px in one frame (${shifts.length} entries, sum ${sum.toFixed(4)}; ${shifts.find((each) => each.maxMove === shiftMove)?.mover ?? "no node"})`,
            );
        }
        expect(failures).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
