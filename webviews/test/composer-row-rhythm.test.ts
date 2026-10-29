// The composer's controls row keeps one rhythm (Leo 2026-10-14: "the footer controls are spaced
// unevenly, with big random gaps between 'Claude Opus', 'Medium', 'Normal' and 'Trusted this
// chat's…'. Use one consistent gap, group related controls, and right-align the trailing cluster").
//
// The controls sit in two rows (Leo 2026-10-19, Claude Code's split): the box holds [+] beside the
// prompt and [↵ · Stop · mic] after it, on the prompt's last line (Leo 2026-10-20, the Claude desktop
// composer); the quiet row under it is [permission mode · Plan] ……… [model]. The model button names
// its effort too ("Opus 5.5  Medium", Leo 2026-10-20): there is no effort chip.
// Each row keeps the rhythm on its own.
// What a person sees between two controls is the space between what each draws (its text, its
// icons' boxes, or Send's disc), not between their transparent hit boxes, so this measures that.
// An icon counts as its box, not its strokes: icons share one grid, so equal box gaps read as equal.
// The mic may be absent (a short row):
//   - inside a group, every control is the same distance from the next (within 1 px);
//   - between the leading groups, every gap is the same, and larger than the in-group gap;
//   - inside the chips (model, permission mode, Interrupt), the text sits the same distance
//     from the chip's leading and trailing edges, and an icon or chevron the same distance from the
//     text, in every chip of the same row;
//   - in the box, + and the last control sit the same distance from the box's sides: the + glyph's
//     center and the last control's center 22 px in (composer-alignment-centers.test.ts, 2026-10-27).
//     How far they sit off the box's bottom follows the prompt's last line, so that test owns it.
//
// It renders the real composer (the gallery's `agent-pane.composer-row` entry, a running Claude chat
// with text typed so Interrupt shows beside the mic and Send) in Chromium at four pane widths.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Span = { left: number; right: number; bottom?: number };
type Control = {
  name: string;
  /** The control's hit box. */
  box: Span;
  /** What it draws, leading to trailing: text runs and icons (Send: its disc). */
  parts: { kind: "text" | "icon" | "disc"; left: number; right: number; bottom?: number }[];
  /** The shared down-chevron's optical correction, when this control has one. */
  chevronY?: number;
};
type Row = { bar: Span; content: Span; controls: Control[] };

await requireBrowserLane("composer-row-rhythm.test.ts", async () => {
  /** Runs in the page: each visible control of the row and what it draws. */
  function measure(selector: string): Row {
    const bar = document.querySelector<HTMLElement>(selector)!;
    const barRect = bar.getBoundingClientRect();
    const barBottom = barRect.bottom;
    const style = getComputedStyle(bar);
    const named: [string, string][] = [
      ["plus", ".acpmux-composer-plus .acpmux-picker-button"],
      ["model", ".acpmux-model .acpmux-picker-button"],
      ["mode", ".acpmux-access-trigger"],
      ["plan", ".acpmux-plan"],
      ["steer", ".acpmux-steer-now"],
      ["mic", ".acpmux-mic"],
      ["send", ".acpmux-send:not(.acpmux-steer-now)"],
    ];
    const shown = (element: Element) => {
      for (let node: Element | null = element; node && node !== bar; node = node.parentElement) {
        const css = getComputedStyle(node);
        if (css.display === "none" || css.visibility !== "visible" || css.opacity === "0") return false;
      }
      return element.getBoundingClientRect().width > 0;
    };
    const controls = named.flatMap(([name, selector]): Control[] => {
      const element = bar.querySelector<HTMLElement>(selector);
      if (!element || !shown(element)) return [];
      const rect = element.getBoundingClientRect();
      const parts: Control["parts"] = [];
      const chevron = element.querySelector<SVGElement>(":scope > .acpmux-icon:last-child");
      const chevronTransform = chevron ? getComputedStyle(chevron).transform : "none";
      const chevronY =
        chevronTransform !== "none"
          ? Number.parseFloat(chevronTransform.match(/matrix\([^,]+,[^,]+,[^,]+,[^,]+,[^,]+,([^)]+)\)/)?.[1] ?? "NaN")
          : undefined;
      const disc = getComputedStyle(element).backgroundColor;
      if ((name === "send" || name === "steer") && disc !== "rgba(0, 0, 0, 0)" && disc !== "transparent")
        parts.push({ kind: "disc", left: rect.left, right: rect.right, bottom: rect.bottom });
      else {
        const walk = (node: Node) => {
          if (node instanceof SVGSVGElement) {
            if (shown(node)) {
              const box = node.getBoundingClientRect();
              parts.push({ kind: "icon", left: box.left, right: box.right });
            }
            return;
          }
          if (node.nodeType === Node.TEXT_NODE) {
            if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) return;
            const range = document.createRange();
            range.selectNodeContents(node);
            const box = range.getBoundingClientRect();
            // A label cut by its box (an ellipsis) draws only inside that box.
            let left = box.left;
            let right = box.right;
            for (
              let clip: Element | null = node.parentElement;
              clip && clip !== element.parentElement;
              clip = clip.parentElement
            )
              if (getComputedStyle(clip).overflowX !== "visible") {
                const bounds = clip.getBoundingClientRect();
                left = Math.max(left, bounds.left);
                right = Math.min(right, bounds.right);
              }
            if (right - left > 0) parts.push({ kind: "text", left, right });
            return;
          }
          if (node instanceof HTMLElement) {
            // A label drawn by a pseudo-element (content: attr(...)) has no text node of its own.
            const before = getComputedStyle(node, "::before").content;
            if (before && before !== "none" && before !== "normal" && before !== '""' && shown(node)) {
              const box = node.getBoundingClientRect();
              if (box.width > 0) parts.push({ kind: "text", left: box.left, right: box.right });
            }
          }
          for (const child of node.childNodes) walk(child);
        };
        walk(element);
      }
      parts.sort((a, b) => a.left - b.left);
      return [{ name, box: { left: rect.left, right: rect.right, bottom: rect.bottom }, parts, chevronY }];
    });
    controls.sort((a, b) => a.box.left - b.box.left);
    return {
      bar: { left: barRect.left, right: barRect.right, bottom: barBottom },
      content: {
        left: barRect.left + parseFloat(style.paddingLeft) + parseFloat(style.borderLeftWidth),
        right: barRect.right - parseFloat(style.paddingRight) - parseFloat(style.borderRightWidth),
      },
      controls,
    };
  }

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-row-rhythm: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer row rhythm", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-row", { variant, theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer-row", { browser, params: { variant: "queued" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A running Claude chat with a prompt typed, so the mic, ↵ and Stop all show. */
  const row = async (width: number, scheme: string) => {
    const page = await browser!.newPage({ viewport: { width, height: 300 } });
    await page.goto(stageURL("queued", scheme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-model .acpmux-model-detail:visible").first().waitFor();
    await page.locator(".acpmux-composer-box [contenteditable='true'], .acpmux-composer-box textarea").first().click();
    await page.keyboard.type("Also cover the 503 path");
    await page.locator(".acpmux-steer-now").waitFor();
    await page.evaluate(() => document.fonts.ready);
    // Let the row's fit pass (composerRowFit.ts) settle after the typed text.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    // The box's own controls lay out in the box itself (the bar draws no box of its own).
    const inner = await page.evaluate(measure, ".acpmux-composer-box");
    const foot = await page.evaluate(measure, ".acpmux-composer-foot");
    await page.close();
    return { inner, foot };
  };

  // The leading groups, then the trailing cluster (last) of each row.
  const GROUPS = [["plus"], ["mode", "plan"], ["model"], ["steer", "mic", "send"]];
  const TRAILING = new Set([2, 3]);
  const group = (name: string) => GROUPS.findIndex((members) => members.includes(name));
  const drawn = (control: Control): Span => ({
    left: control.parts[0]?.left ?? control.box.left,
    right: control.parts.at(-1)?.right ?? control.box.right,
  });

  for (const width of [760, 600, 480, 420])
    for (const scheme of ["light", "dark"])
      test(`at ${width} px (${scheme}): one gap in a group, one between groups, Send at the edge`, async () => {
        const rows = await row(width, scheme);
        const problems: string[] = [];
        const spread = (values: number[]) => (values.length > 1 ? Math.max(...values) - Math.min(...values) : 0);
        const list = (gaps: { between: string; gap: number }[]) =>
          gaps.map(({ between, gap }) => `${between} ${gap.toFixed(1)}`).join(", ");
        // Each row keeps its own rhythm: the box's icon buttons and the quiet row's text chips
        // are different sizes, as Claude Code's are, so gaps compare only within a row.
        for (const [rowName, measured] of Object.entries(rows)) {
          const { controls } = measured;
          const insides: {
            name: string;
            lead: number;
            trail: number;
            iconGap?: number;
            chevronGap?: number;
            shape: string;
          }[] = [];
          const inGroup: { between: string; gap: number }[] = [];
          const betweenGroups: { between: string; gap: number }[] = [];
          for (let index = 1; index < controls.length; index++) {
            const before = controls[index - 1]!;
            const after = controls[index]!;
            // The row's free space sits between the leading groups and the trailing cluster.
            if (TRAILING.has(group(after.name)) && !TRAILING.has(group(before.name))) continue;
            const gap = { between: `${before.name}→${after.name}`, gap: drawn(after).left - drawn(before).right };
            (group(before.name) === group(after.name) ? inGroup : betweenGroups).push(gap);
          }
          // Inside each chip: the text's inset from the leading and trailing edges, and the space
          // between an icon or chevron and the text.
          for (const control of controls.filter((control) => ["model", "mode", "plan"].includes(control.name))) {
            const { parts, box } = control;
            const gaps = parts.slice(1).map((part, index) => part.left - parts[index]!.right);
            insides.push({
              name: control.name,
              lead: parts[0] ? parts[0].left - box.left : 0,
              trail: parts.at(-1) ? box.right - parts.at(-1)!.right : 0,
              // Leading icon to text, and text to chevron, where the chip draws them.
              iconGap: parts[0]?.kind === "icon" && parts[1]?.kind === "text" ? gaps[0] : undefined,
              chevronGap: parts.at(-1)?.kind === "icon" && parts.at(-2)?.kind === "text" ? gaps.at(-1) : undefined,
              shape: parts.map((part) => part.kind).join("+"),
            });
          }
          // The quiet row's hover pill is the native selection pill's size (Leo 2026-10-22: "the
          // highlight pill is too small"): its text sits 8 px in from the pill's leading edge.
          if (rowName === "foot")
            for (const inside of insides)
              if (inside.lead < 7.5)
                problems.push(
                  `foot: ${inside.name}'s pill starts ${inside.lead.toFixed(1)} px before its text, not 8 px`,
                );
          // Location and composer pickers share the same optical correction for their down-chevron.
          // The model button draws none, as Claude Code's (Leo 2026-10-20); the mode keeps its own.
          for (const control of controls.filter(({ name }) => name === "mode"))
            if (control.chevronY === undefined || Math.abs(control.chevronY - 0.75) > 0.05)
              problems.push(`${control.name} chevron transform is ${control.chevronY ?? "missing"}, expected 0.75`);
          console.log(
            JSON.stringify({
              width,
              scheme,
              row: rowName,
              names: controls.map((control) => control.name),
              boxGaps: controls
                .slice(1)
                .map(
                  (control, index) =>
                    `${controls[index]!.name}→${control.name} ${(control.box.left - controls[index]!.box.right).toFixed(1)}`,
                ),
            }),
          );
          console.log(
            JSON.stringify({
              width,
              scheme,
              row: rowName,
              inGroup: list(inGroup),
              betweenGroups: list(betweenGroups),
              insides,
            }),
          );
          if (spread(inGroup.map(({ gap }) => gap)) > 1)
            problems.push(`${rowName}: uneven gaps inside groups: ${list(inGroup)}`);
          if (spread(betweenGroups.map(({ gap }) => gap)) > 1)
            problems.push(`${rowName}: uneven gaps between groups: ${list(betweenGroups)}`);
          const tight = Math.max(0, ...inGroup.map(({ gap }) => gap));
          for (const { between, gap } of betweenGroups)
            if (gap <= tight + 1)
              problems.push(`${rowName}: ${between} ${gap.toFixed(1)} is not wider than the in-group gap`);
          for (const key of ["lead", "trail", "iconGap", "chevronGap"] as const) {
            const values = insides.flatMap((inside) => (inside[key] === undefined ? [] : [inside[key]!]));
            if (spread(values) > 1)
              problems.push(
                `${rowName}: chips' ${key} differs: ${insides.map((inside) => `${inside.name} ${inside[key]?.toFixed(1) ?? "-"}`).join(", ")}`,
              );
          }
        }
        const names = (measured: Row) => measured.controls.map((control) => control.name);
        // The mic may leave a short row; the rest always shows, each in its row.
        for (const name of ["plus", "steer", "send"])
          if (!names(rows.inner).includes(name)) problems.push(`${name} is not in the box's row`);
        for (const name of ["model", "mode"])
          if (!names(rows.foot).includes(name)) problems.push(`${name} is not in the quiet row`);
        // The box's columns (composer-alignment-centers.test.ts, Leo's report 2026-10-27, which
        // replaced Claude desktop's 16 px + glyph inset of 2026-10-20): the + button and the last
        // control (the mic; Stop sits left of it) are 28 px boxes 8 px in from the box's sides, so
        // the + glyph's center and the last control's center both sit 22 px in. Their distance off
        // the bottom centers them on the prompt's last line, which follows the chat's font size
        // (#26523), so it no longer equals the side inset.
        const { inner } = rows;
        const first = inner.controls[0];
        const last = inner.controls.at(-1);
        const leadCenter = first ? (drawn(first).left + drawn(first).right) / 2 - inner.bar.left : 0;
        const trailCenter = last ? inner.bar.right - (last.box.left + last.box.right) / 2 : 0;
        if (first && Math.abs(leadCenter - 22) > 1)
          problems.push(`the + glyph's center sits ${leadCenter.toFixed(1)} px in, not 22 px`);
        if (last && Math.abs(trailCenter - 22) > 1)
          problems.push(`${last.name}'s center sits ${trailCenter.toFixed(1)} px in from the right, not 22 px`);
        expect(problems).toEqual([]);
      });
});
