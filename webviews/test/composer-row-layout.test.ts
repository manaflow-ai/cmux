// The composer's controls row and footer (hq#1957 item 15). Leo saw a huge empty gap between
// Effort and the permission chip while the model and effort chips truncated ("Claude Opu…",
// "Med…"), and the folder footer cut at the card's bottom edge. In the gallery's
// `agent-pane.composer-row` entry at a narrow, a normal and a wide pane:
//   - the controls are two clusters: + model effort access on the left, mic and Send (or Stop)
//     on the right; the row's free space sits only between the two;
//   - the row is compact and calm (hq#1957 item 15 compact row): the left cluster's controls sit
//     8 to 12 px apart, evenly (within 1 px); no context ring or spinner in the row; one lock at
//     most; no granted-permission status chip; Stop has Send's footprint and a square glyph of at
//     most 12 px;
//   - no label is cut while the row has free space, and a short row cuts by priority: the
//     permission labels go to icons first, then effort shortens, the model last;
//   - the folder and computer controls sit whole inside the location strip on the card's top edge
//     (hq#1957 composer location strip; composer-location-strip.test.ts measures the strip itself).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rect = { left: number; right: number; top: number; bottom: number; width: number };
type Row = {
  bar: Rect;
  box: Rect;
  footer: Rect;
  footerControls: Rect[];
  /** Left cluster controls in order, with the free space after the last one. */
  left: { name: string; rect: Rect }[];
  right: Rect;
  barGap: number;
  /** Each label: cut (an ellipsis or a label pushed out of its chip) or whole. */
  labels: Record<string, { cut: boolean; dropped: boolean; atMin: boolean; need: number } | undefined>;
  /** Rings and spinners in the row (the context ring was one). */
  spinners: string[];
  /** Lock icons drawn in the row. */
  locks: number;
  /** Whether the granted-permission status chip sits in the row. */
  status: boolean;
  /** Send or Stop, whichever shows, and Stop's glyph. */
  send: Rect | undefined;
  stop: Rect | undefined;
  stopGlyph: Rect | undefined;
  /** Send's or Stop's fill, whichever shows. */
  fill: string;
};

await requireBrowserLane("composer-row-layout.test.ts", async () => {
  /** Runs in the page: the row's geometry. */
  function measure(): Row {
    const rect = (element: Element): Rect => {
      const { left, right, top, bottom, width } = element.getBoundingClientRect();
      return { left, right, top, bottom, width };
    };
    const visible = (element: Element | null): element is HTMLElement =>
      element instanceof HTMLElement && element.getBoundingClientRect().width > 0;
    const bar = document.querySelector(".acpmux-composer-bar")!;
    const box = document.querySelector(".acpmux-composer-box")!;
    const footer = document.querySelector(".acpmux-composer-strip")!;
    const named: [string, string][] = [
      ["plus", ".acpmux-composer-plus .acpmux-picker-button"],
      ["model", ".acpmux-model .acpmux-picker-button"],
      ["effort", ".acpmux-effort .acpmux-picker-button"],
      ["access", ".acpmux-access-trigger"],
      ["plan", ".acpmux-plan"],
    ];
    const left = named.flatMap(([name, selector]) => {
      const element = bar.querySelector(selector);
      return visible(element) ? [{ name, rect: rect(element) }] : [];
    });
    left.sort((a, b) => a.rect.left - b.rect.left);
    // A label is cut when its text overflows its box, or when it is laid out outside its chip
    // (wrapped away) or not drawn while the chip still is.
    const label = (chip: string, text: string, item: string) => {
      const button = bar.querySelector(chip);
      if (!visible(button)) return undefined;
      const span = button.querySelector(text);
      const shown =
        span instanceof HTMLElement &&
        span.getClientRects().length > 0 &&
        getComputedStyle(span).visibility === "visible";
      const inside =
        shown &&
        span.getBoundingClientRect().top >= button.getBoundingClientRect().top - 0.5 &&
        span.getBoundingClientRect().bottom <= button.getBoundingClientRect().bottom + 0.5 &&
        span.getBoundingClientRect().width > 0;
      const overflow = shown && span.scrollWidth > span.clientWidth + 0.5;
      const host = bar.querySelector(item) ?? button;
      const min = parseFloat(getComputedStyle(host).minWidth) || 0;
      // The width the whole label would take back: an ellipsis's overflow, or a label dropped
      // for its icon with the gap beside it.
      const need = !shown
        ? (span instanceof HTMLElement ? span.getBoundingClientRect().width : 0) +
          (parseFloat(getComputedStyle(button).columnGap) || 0)
        : overflow
          ? span.scrollWidth - span.clientWidth
          : 0;
      return { cut: !inside || overflow, dropped: !shown, atMin: host.getBoundingClientRect().width <= min + 1, need };
    };
    return {
      bar: rect(bar),
      box: rect(box),
      footer: rect(footer),
      footerControls: [...footer.querySelectorAll(".acpmux-location-button, .acpmux-location-readonly")].map(rect),
      left,
      right: rect(bar.querySelector(".acpmux-composer-actions")!),
      barGap: parseFloat(getComputedStyle(bar).columnGap) || 0,
      labels: {
        model: label(".acpmux-model .acpmux-picker-button", ".acpmux-model-name", ".acpmux-model"),
        effort: label(".acpmux-effort .acpmux-picker-button", "span", ".acpmux-effort"),
        access: label(".acpmux-access-trigger", ".acpmux-mode-text", ".acpmux-access"),
      },
      spinners: [
        ...bar.querySelectorAll(
          '.acpmux-context, .acpmux-context-ring, [role="progressbar"], [class*="spinner"], [class*="-ring"]',
        ),
      ].map((element) => element.className.toString() || element.tagName),
      // LockIcon (ComposerPickers.tsx): its shackle path.
      locks: bar.querySelectorAll('svg path[d^="M5.5 7V5.6"]').length,
      status: bar.querySelector(".acpmux-permission-status") !== null,
      send: bar.querySelector(".acpmux-send:not(.acpmux-cancel)")
        ? rect(bar.querySelector(".acpmux-send:not(.acpmux-cancel)")!)
        : undefined,
      stop: bar.querySelector(".acpmux-cancel") ? rect(bar.querySelector(".acpmux-cancel")!) : undefined,
      stopGlyph: bar.querySelector(".acpmux-cancel svg rect")
        ? rect(bar.querySelector(".acpmux-cancel svg rect")!)
        : undefined,
      fill: getComputedStyle(bar.querySelector(".acpmux-send")!).backgroundColor,
    };
  }

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-row-layout: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer row layout", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.composer-row&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 720, height: 300 } });
    await warm.goto(stageURL("claude-auto"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const row = async (variant: string, width: number) => {
    const page = await browser!.newPage({ viewport: { width, height: 300 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-effort .acpmux-picker-button").waitFor();
    await page.evaluate(() => document.fonts.ready);
    const measured = await page.evaluate(measure);
    await page.close();
    return measured;
  };

  for (const variant of ["claude-auto", "long-model", "granted", "queued"])
    for (const width of [420, 720, 1100])
      test(`${variant} at ${width} px: two clusters, cut by priority, strip whole`, async () => {
        const measured = await row(variant, width);
        const { left, right, labels, barGap } = measured;
        const names = left.map((control) => control.name);
        const problems: string[] = [];
        // The left cluster is contiguous: no control sits apart from the one before it.
        for (let index = 1; index < left.length; index++) {
          const gap = left[index]!.rect.left - left[index - 1]!.rect.right;
          if (gap > barGap + 0.5)
            problems.push(`${Math.round(gap)} px gap between ${names[index - 1]} and ${names[index]}`);
        }
        // The permission mode follows effort directly, in the left cluster.
        if (names.indexOf("access") < names.indexOf("effort"))
          problems.push(`access is not after effort: ${names.join(", ")}`);
        // The free space is only between the clusters; a cut label means there is none.
        const free = right.left - left.at(-1)!.rect.right - barGap;
        // A label dropped for its icon is a step: the row may keep less than that label's width.
        const cut = Object.entries(labels).flatMap(([name, label]) => (label?.cut ? [name] : []));
        for (const name of cut)
          if (labels[name]!.dropped ? free >= labels[name]!.need - 0.5 : free > 1)
            problems.push(`${name} cut with ${Math.round(free)} px free in the row`);
        // Priority: the permission label goes first, then effort, the model last.
        if (labels.effort?.cut && labels.access?.cut === false)
          problems.push("effort is cut while the permission label shows");
        if (labels.model?.cut && (labels.effort?.atMin === false || labels.access?.cut === false))
          problems.push("the model is cut before effort and the permission label");
        // At a normal and a wide pane every label of Leo's row shows whole.
        if (width >= 720 && variant !== "long-model" && cut.length > 0)
          problems.push(`${cut.join(", ")} cut at ${width} px`);
        // The location strip heads the card, its controls whole inside it.
        if (Math.abs(measured.footer.bottom - measured.box.top) > 1)
          problems.push("the strip is not on the card's top edge");
        for (const control of measured.footerControls) {
          if (control.top < measured.footer.top - 0.5 || control.bottom > measured.footer.bottom + 0.5)
            problems.push("a strip control runs out of the strip");
          if (control.left < measured.footer.left - 0.5) problems.push("a strip control runs out of the strip's side");
        }
        expect(problems).toEqual([]);
      });

  for (const variant of ["claude-auto", "long-model", "granted", "queued"])
    for (const width of [420, 720, 1100])
      test(`${variant} at ${width} px: a compact, calm row`, async () => {
        const measured = await row(variant, width);
        const problems: string[] = [];
        // Even gaps in the left cluster: each 8 to 12 px, none more than 1 px off another.
        const gaps = measured.left.slice(1).map((control, index) => ({
          between: `${measured.left[index]!.name}-${control.name}`,
          gap: control.rect.left - measured.left[index]!.rect.right,
        }));
        for (const { between, gap } of gaps)
          if (gap < 7.5 || gap > 12.5) problems.push(`${between} ${gap.toFixed(1)} px apart`);
        const sizes = gaps.map(({ gap }) => gap);
        if (sizes.length > 1 && Math.max(...sizes) - Math.min(...sizes) > 1)
          problems.push(`uneven gaps ${gaps.map(({ between, gap }) => `${between} ${gap.toFixed(1)}`).join(", ")}`);
        if (measured.spinners.length > 0)
          problems.push(`a ring or spinner in the row: ${measured.spinners.join(", ")}`);
        if (measured.locks > 1) problems.push(`${measured.locks} locks in the row`);
        if (measured.status) problems.push("the granted-permission status chip is in the row");
        if (measured.stopGlyph) {
          const { width: w, bottom, top } = measured.stopGlyph;
          if (Math.abs(w - (bottom - top)) > 0.5 || w > 12)
            problems.push(`Stop's glyph is ${w.toFixed(1)} x ${(bottom - top).toFixed(1)} px`);
        }
        expect(problems).toEqual([]);
      });

  for (const width of [420, 720, 1100])
    test(`at ${width} px Stop takes Send's box and circle`, async () => {
      const idle = await row("claude-auto", width);
      const running = await row("queued", width);
      const send = idle.send!;
      const stop = running.stop!;
      expect(stop).toBeDefined();
      const off = (["left", "right", "top", "bottom"] as const).filter(
        (side) => Math.abs(send[side] - stop[side]) > 0.5,
      );
      expect(off.map((side) => `${side} ${send[side].toFixed(1)} -> ${stop[side].toFixed(1)}`)).toEqual([]);
      // The same circle as Send (its resting fill), not a disc of its own.
      expect(running.fill).toBe(idle.fill);
    });
});
