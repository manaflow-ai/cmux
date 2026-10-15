// The composer's controls row never cuts a label (Leo 2026-10-14: "Claude Opus …", "Medi…" in the
// footer), and effort is a chip of its own (Leo 2026-10-15: "move it back out"). A narrower
// composer swaps whole units, never letters, and shortens labels before it drops a control
// (cg-ui-coord 2026-10-15: "collapse faster and keep more visible"):
//   - always: +, the model, effort, the access glyph, Send and every chevron; no label under 3
//     characters; no two controls overlap;
//   - first effort shows the level's short name ("Med"), then the model its family ("Opus"), then
//     its harness mark alone (its name in its tooltip);
//   - only then the access label goes, and the mic last.
// At every width each label is whole, never clipped or ellipsized, and the row stays in the bar.
//
// The gallery's `agent-pane.composer-row` entry (`leo-report`) is the real pane in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Control = {
  /** The labels the control draws (text nodes and ::before text), left to right. */
  labels: string[];
  /** A visible label overflowing its box, or drawn outside its control. */
  clipped: string[];
  chevron: boolean;
  title: string;
  rect: { left: number; right: number; top: number; bottom: number };
};
type Measured = { controls: Record<string, Control | undefined>; overflow: string[] };

await requireBrowserLane("composer-row-steps.test.ts", async () => {
  /** Runs in the page. */
  function measure(): Measured {
    const bar = document.querySelector<HTMLElement>(".acpmux-composer-bar")!;
    const shown = (element: Element) =>
      element.getClientRects().length > 0 &&
      getComputedStyle(element).visibility === "visible" &&
      Number(getComputedStyle(element).opacity) > 0;
    const control = (selector: string): Control | undefined => {
      const button = bar.querySelector<HTMLElement>(selector);
      if (!button || !shown(button) || button.getBoundingClientRect().width < 1) return undefined;
      const box = button.getBoundingClientRect();
      const found: [string, Element][] = [];
      const walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode())
        if (node.textContent?.trim() && node.parentElement) found.push([node.textContent.trim(), node.parentElement]);
      for (const element of [button, ...button.querySelectorAll("*")]) {
        const content = getComputedStyle(element, "::before").content;
        if (/^".+"$/.test(content)) found.push([content.slice(1, -1).trim(), element]);
      }
      found.sort(([, a], [, b]) => a.getBoundingClientRect().left - b.getBoundingClientRect().left);
      const labels: string[] = [];
      const clipped: string[] = [];
      for (const [value, element] of found) {
        if (!shown(element)) continue;
        labels.push(value);
        const rect = element.getBoundingClientRect();
        if (element.scrollWidth > element.clientWidth + 0.5 && getComputedStyle(element).display !== "inline")
          clipped.push(`"${value}" overflows its box by ${element.scrollWidth - element.clientWidth} px`);
        if (rect.left < box.left - 0.5 || rect.right > box.right + 0.5)
          clipped.push(`"${value}" runs outside its control`);
      }
      // ChevronIcon (ComposerPickers.tsx): its path.
      const chevron = [...button.querySelectorAll('svg path[d^="M4.6 6.3"]')].some((path) => shown(path));
      const { left, right, top, bottom } = box;
      return { labels, clipped, chevron, title: button.title, rect: { left, right, top, bottom } };
    };
    const overflow: string[] = [];
    if (bar.scrollWidth > bar.clientWidth + 0.5)
      overflow.push(`the bar scrolls ${bar.scrollWidth - bar.clientWidth} px`);
    const right = bar.getBoundingClientRect().right - parseFloat(getComputedStyle(bar).paddingRight);
    const send = bar.querySelector(".acpmux-send")?.getBoundingClientRect();
    if (send && send.right > right + 0.5) overflow.push("Send runs past the bar");
    return {
      controls: {
        plus: control(".acpmux-composer-plus .acpmux-picker-button"),
        model: control(".acpmux-model .acpmux-picker-button"),
        effort: control(".acpmux-effort .acpmux-picker-button"),
        access: control(".acpmux-access-trigger"),
        mic: control(".acpmux-mic"),
        send: control(".acpmux-send"),
      },
      overflow,
    };
  }

  /** What each pane width shows (the composer is the pane less 36 px): the model chip's labels,
   *  effort's, the access label, the mic. */
  const EXPECTED: Record<number, { model: string; effort: string; access: string; mic: boolean }> = {
    760: { model: "Opus 5.5", effort: "Medium Fast", access: "Auto", mic: true },
    520: { model: "Opus 5.5", effort: "Medium Fast", access: "Auto", mic: true },
    500: { model: "Opus 5.5", effort: "Med Fast", access: "Auto", mic: true },
    460: { model: "Opus", effort: "Med Fast", access: "Auto", mic: true },
    440: { model: "Opus", effort: "Med Fast", access: "", mic: true },
    400: { model: "", effort: "Med Fast", access: "", mic: true },
    360: { model: "", effort: "Med Fast", access: "", mic: false },
    300: { model: "", effort: "Med Fast", access: "", mic: false },
    280: { model: "", effort: "Med Fast", access: "", mic: false },
  };

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-row-steps: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer row steps", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.composer-row&variant=leo-report`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 760, height: 300 } });
    await warm.goto(stageURL());
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

  const at = async (width: number) => {
    const page = await browser!.newPage({ viewport: { width, height: 300 } });
    await page.goto(stageURL());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-model .acpmux-picker-button").waitFor();
    await page.evaluate(() => document.fonts.ready);
    // Two frames: the row's fit runs on layout and on its resize observer.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const measured = await page.evaluate(measure);
    await page.close();
    return measured;
  };

  for (const [width, expected] of Object.entries(EXPECTED).map(([w, e]) => [Number(w), e] as const))
    test(`at ${width} px the row swaps whole units: model "${expected.model}", effort "${expected.effort}"`, async () => {
      const { controls, overflow } = await at(width);
      const problems = [...overflow];
      for (const [name, control] of Object.entries(controls)) {
        if (!control) continue;
        for (const clip of control.clipped) problems.push(`${name}: ${clip}`);
        for (const label of control.labels) {
          if (/…|\.\.\./.test(label)) problems.push(`${name} draws an ellipsis: "${label}"`);
          if (label.length < 3) problems.push(`${name} draws "${label}", under 3 characters`);
        }
      }
      for (const name of ["plus", "model", "effort", "access", "send"])
        if (!controls[name]) problems.push(`no ${name} in the row`);
      const effort = controls.effort?.labels.join(" ") ?? "";
      if (effort !== expected.effort) problems.push(`the effort chip reads "${effort}", not "${expected.effort}"`);
      const model = controls.model?.labels.join(" ") ?? "";
      if (model !== expected.model) problems.push(`the model chip reads "${model}", not "${expected.model}"`);
      if (!expected.model && !/Opus 5\.5/.test(controls.model?.title ?? ""))
        problems.push(`the model's mark has no tooltip naming it: "${controls.model?.title}"`);
      const access = controls.access?.labels.join(" ") ?? "";
      if (access !== expected.access) problems.push(`the access chip reads "${access}", not "${expected.access}"`);
      if (Boolean(controls.mic) !== expected.mic)
        problems.push(expected.mic ? "no mic" : "the mic is still in the row");
      for (const name of ["model", "effort", "access"])
        if (controls[name] && !controls[name].chevron) problems.push(`${name} lost its chevron`);
      // No two controls overlap.
      const shown = Object.entries(controls).filter(([, control]) => control) as [string, Control][];
      for (let i = 0; i < shown.length; i++)
        for (let j = i + 1; j < shown.length; j++) {
          const [a, ra] = [shown[i]![0], shown[i]![1].rect];
          const [b, rb] = [shown[j]![0], shown[j]![1].rect];
          const x = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left);
          const y = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
          if (x > 0.5 && y > 0.5) problems.push(`${a} overlaps ${b} by ${x.toFixed(1)} px`);
        }
      expect(problems).toEqual([]);
    });
});
