// The composer's controls row never cuts a label (Leo 2026-10-14: "Claude Opus …", "Medi…" in the
// footer). The model and its effort are one button, "Opus 5.5  Medium" (Leo 2026-10-20), with no
// effort chip and no speed button beside it: Fast mode is a row of that button's menu. A narrower
// composer swaps whole units, never letters, and shortens labels before it drops a control
// (cg-ui-coord 2026-10-15: "collapse faster and keep more visible"). At every width, in either
// look: +, the model button with its effort, the access glyph, Send (with a draft typed) and the
// access chevron show; no label is under 3 characters; no two controls overlap; the mic never
// leaves (Leo 2026-10-19: the prompt shrinks instead); each label is whole, never clipped or
// ellipsized, and the row stays in its bar.
//
// Two looks, two tables:
//   - The quiet row (the default plain footer, #22285; Leo 2026-10-19, as Claude Code's): +, the
//     mic and Send in the box, the mode and the model button in a row of their own under it. That
//     row takes no composer-width step (composerRowFit.ts paneWidth): it holds the mode, the model
//     button and the ring, so it keeps "Opus 5.5  Medium" and "Auto" while they fit (live-qa
//     2026-10-21 read "Opus Med" with about 250 px of the row free), and shortens the effort only
//     when they do not (below a 280 px pane: test/composer-model-quiet.test.ts measures it).
//   - The stepped row (Debug Settings' plain footer off): the same row element, without
//     `data-footer-look="plain"`, where the composer's width steps still apply as they did when
//     every control shared one row. First the button's effort shows the level's short name ("Med"),
//     then the model its family ("Opus"), the access label goes, then the model its harness mark
//     alone (its name in its tooltip), the effort still beside it.
//
// The gallery's `agent-pane.composer-row` entry (`leo-report`) is the real pane in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Control = {
  /** The labels the control draws (text nodes and ::before text), left to right. */
  labels: string[];
  /** Of `labels`, the ones the model button draws for its effort (`.acpmux-model-detail`). */
  detail: string[];
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
    const bars = [...document.querySelectorAll<HTMLElement>(".acpmux-composer .acpmux-composer-bar")];
    const find = (selector: string) =>
      bars.map((bar) => bar.querySelector<HTMLElement>(selector)).find((button) => button) ?? null;
    const shown = (element: Element) =>
      element.getClientRects().length > 0 &&
      getComputedStyle(element).visibility === "visible" &&
      Number(getComputedStyle(element).opacity) > 0;
    const control = (selector: string): Control | undefined => {
      const button = find(selector);
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
      const detail: string[] = [];
      const clipped: string[] = [];
      for (const [value, element] of found) {
        if (!shown(element)) continue;
        labels.push(value);
        if (element.closest(".acpmux-model-detail")) detail.push(value);
        const rect = element.getBoundingClientRect();
        if (element.scrollWidth > element.clientWidth + 0.5 && getComputedStyle(element).display !== "inline")
          clipped.push(`"${value}" overflows its box by ${element.scrollWidth - element.clientWidth} px`);
        if (rect.left < box.left - 0.5 || rect.right > box.right + 0.5)
          clipped.push(`"${value}" runs outside its control`);
      }
      // ChevronIcon (ComposerPickers.tsx): its path.
      const chevron = [...button.querySelectorAll('svg path[d^="M4.6 6.3"]')].some((path) => shown(path));
      const { left, right, top, bottom } = box;
      return { labels, detail, clipped, chevron, title: button.title, rect: { left, right, top, bottom } };
    };
    const overflow: string[] = [];
    for (const bar of bars) {
      if (bar.scrollWidth > bar.clientWidth + 0.5)
        overflow.push(`the bar scrolls ${bar.scrollWidth - bar.clientWidth} px`);
      // A bar that draws no box (display: contents, the Claude desktop box) lays its controls in
      // the box's own grid: Send keeps inside the box's padding box then.
      const frame = getComputedStyle(bar).display === "contents" ? bar.closest(".acpmux-composer-box")! : bar;
      const right = frame.getBoundingClientRect().right - parseFloat(getComputedStyle(frame).paddingRight);
      const send = bar.querySelector(".acpmux-send")?.getBoundingClientRect();
      if (send && send.right > right + 0.5) overflow.push("Send runs past the bar");
    }
    return {
      controls: {
        plus: control(".acpmux-composer-plus .acpmux-picker-button"),
        model: control(".acpmux-model .acpmux-picker-button"),
        access: control(".acpmux-access-trigger"),
        // Gone since Leo 2026-10-20 (one model button, Fast mode in its menu): must stay absent.
        effortChip: control(".acpmux-effort .acpmux-picker-button"),
        bolt: control(".acpmux-fast"),
        mic: control(".acpmux-mic"),
        send: control(".acpmux-send"),
      },
      overflow,
    };
  }

  type Expected = { model: string; effort: string; access: string; mic: boolean };
  /** The quiet row under the box (the default look): no width takes a step; the row's measured room
   *  does. Since #24938 took the harness label out of it, the row holds only the mode, the model
   *  button and the context ring, so it keeps every whole label down to a 280 px pane (a 244 px
   *  composer). Below that it does run out, which test/composer-model-quiet.test.ts measures
   *  (204 and 164 px composers shorten whole units); every width here checks that nothing is cut,
   *  ellipsized or overlapping while the row still has room. */
  const QUIET: Record<number, Expected> = Object.fromEntries(
    [760, 520, 500, 460, 440, 400, 300, 280].map((width) => [
      width,
      { model: "Opus 5.5", effort: "Medium", access: "Auto", mic: true },
    ]),
  );
  /** The stepped row (plain footer off): what each pane width shows (the composer is the pane less
   *  36 px): the model button's name, its effort (Fast on never adds a word to it), the access
   *  label, the mic (always). */
  const STEPPED: Record<number, Expected> = {
    760: { model: "Opus 5.5", effort: "Medium", access: "Auto", mic: true },
    520: { model: "Opus 5.5", effort: "Medium", access: "Auto", mic: true },
    500: { model: "Opus 5.5", effort: "Med", access: "Auto", mic: true },
    460: { model: "Opus", effort: "Med", access: "Auto", mic: true },
    440: { model: "Opus", effort: "Med", access: "", mic: true },
    400: { model: "", effort: "Med", access: "", mic: true },
    360: { model: "", effort: "Med", access: "", mic: true },
    300: { model: "", effort: "Med", access: "", mic: true },
    280: { model: "", effort: "Med", access: "", mic: true },
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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-row", { variant: "leo-report" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer-row", { browser, params: { variant: "leo-report" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const at = async (width: number, look: "quiet" | "stepped") => {
    const page = await browser!.newPage({ viewport: { width, height: 300 } });
    await page.goto(stageURL());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-model .acpmux-picker-button").waitFor();
    await page.evaluate(() => document.fonts.ready);
    // The plain footer is the default (DEFAULT_COMPOSER.plainFooter); the host's `composer` event
    // turns it off, as Debug Settings does. ComposerFoot draws the same row either way and marks
    // only the plain one `data-footer-look="plain"`, so the look is read off that attribute, not off
    // which element holds the chips.
    await page.locator(".acpmux-composer-foot .acpmux-model .acpmux-picker-button").waitFor();
    if (look === "stepped") {
      await page.evaluate(() => window.cmuxAcpmuxComposer?.({ plainFooter: false }));
      await page
        .locator('.acpmux-composer-foot:not([data-footer-look="plain"]) .acpmux-model .acpmux-picker-button')
        .waitFor();
    } else await page.locator('.acpmux-composer-foot[data-footer-look="plain"]').waitFor();
    // Claude desktop's box: no Send until there is a draft (Leo 2026-10-20). A typed prompt brings
    // Send in, so the row is measured with every control it can hold.
    await page.locator(".acpmux-composer-prompt [contenteditable]").click();
    await page.keyboard.type("Retry");
    await page.locator(".acpmux-composer-actions .acpmux-send").waitFor();
    // Two frames: the row's fit runs on layout and on its resize observer.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const measured = await page.evaluate(measure);
    await page.close();
    return measured;
  };

  const cases = [
    ...Object.entries(QUIET).map(([w, e]) => ["quiet", Number(w), e] as const),
    ...Object.entries(STEPPED).map(([w, e]) => ["stepped", Number(w), e] as const),
  ];
  for (const [look, width, expected] of cases)
    test(`${look} row at ${width} px swaps whole units: model "${expected.model}", effort "${expected.effort}", access "${expected.access}"`, async () => {
      const { controls, overflow } = await at(width, look);
      const problems = [...overflow];
      for (const [name, control] of Object.entries(controls)) {
        if (!control) continue;
        for (const clip of control.clipped) problems.push(`${name}: ${clip}`);
        for (const label of control.labels) {
          if (/…|\.\.\./.test(label)) problems.push(`${name} draws an ellipsis: "${label}"`);
          if (label.length < 3) problems.push(`${name} draws "${label}", under 3 characters`);
        }
      }
      for (const name of ["plus", "model", "access", "send"])
        if (!controls[name]) problems.push(`no ${name} in the row`);
      const effort = controls.model?.detail.join(" ") ?? "";
      if (effort !== expected.effort)
        problems.push(`the model button's effort reads "${effort}", not "${expected.effort}"`);
      const model = controls.model?.labels.filter((label) => !controls.model!.detail.includes(label)).join(" ") ?? "";
      if (model !== expected.model) problems.push(`the model button reads "${model}", not "${expected.model}"`);
      // The effort follows the model's name inside the one button, never a control of its own.
      if (controls.effortChip) problems.push("an effort chip of its own is in the row");
      if (!expected.model && !/Opus 5\.5/.test(controls.model?.title ?? ""))
        problems.push(`the model's mark has no tooltip naming it: "${controls.model?.title}"`);
      const access = controls.access?.labels.join(" ") ?? "";
      if (access !== expected.access) problems.push(`the access chip reads "${access}", not "${expected.access}"`);
      if (controls.bolt) problems.push("a speed button is in the row (Fast mode is a row of the model's menu)");
      if (Boolean(controls.mic) !== expected.mic)
        problems.push(expected.mic ? "no mic" : "the mic is still in the row");
      // The access chip keeps its chevron; the model button, as Claude Code's, draws none.
      if (controls.access && !controls.access.chevron) problems.push("access lost its chevron");
      if (controls.model?.chevron) problems.push("the model button draws a chevron");
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
