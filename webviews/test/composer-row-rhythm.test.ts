// The composer's controls row keeps one rhythm (Leo 2026-10-14: "the footer controls are spaced
// unevenly, with big random gaps between 'Claude Opus', 'Medium', 'Normal' and 'Trusted this
// chat's…'. Use one consistent gap, group related controls, and right-align the trailing cluster").
//
// The row is four groups: [+] [model · effort] [permission mode · Plan] ……… [Interrupt · mic · Send].
// What a person sees between two controls is the space between what each draws (its text, its
// icons' boxes, or Send's disc), not between their transparent hit boxes, so this measures that.
// An icon counts as its box, not its strokes: icons share one grid, so equal box gaps read as equal.
// The effort chip and the mic may be absent (a short row, or effort folded into the model chip):
//   - inside a group, every control is the same distance from the next (within 1 px);
//   - between the leading groups, every gap is the same, and larger than the in-group gap;
//   - inside the chips (model, effort, permission mode, Interrupt), the text sits the same distance
//     from the chip's leading and trailing edges, and an icon or chevron the same distance from the
//     text, in every chip;
//   - the trailing cluster ends at the bar's content edge, so Send lines up with the row's padding.
//
// It renders the real composer (the gallery's `agent-pane.composer-row` entry, a running Claude chat
// with text typed so Interrupt shows beside the mic and Send) in Chromium at four pane widths.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Span = { left: number; right: number };
type Control = {
  name: string;
  /** The control's hit box. */
  box: Span;
  /** What it draws, leading to trailing: text runs and icons (Send: its disc). */
  parts: { kind: "text" | "icon" | "disc"; left: number; right: number }[];
  /** The shared down-chevron's optical correction, when this control has one. */
  chevronY?: number;
};
type Row = { bar: Span; content: Span; controls: Control[] };

await requireBrowserLane("composer-row-rhythm.test.ts", async () => {
  /** Runs in the page: each visible control of the row and what it draws. */
  function measure(): Row {
    const bar = document.querySelector<HTMLElement>(".acpmux-composer-bar")!;
    const barRect = bar.getBoundingClientRect();
    const style = getComputedStyle(bar);
    const named: [string, string][] = [
      ["plus", ".acpmux-composer-plus .acpmux-picker-button"],
      ["model", ".acpmux-model .acpmux-picker-button"],
      ["effort", ".acpmux-effort .acpmux-picker-button"],
      ["mode", ".acpmux-access-trigger"],
      ["plan", ".acpmux-plan"],
      ["steer", ".acpmux-steer"],
      ["mic", ".acpmux-mic"],
      ["send", ".acpmux-send"],
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
          ? Number.parseFloat(chevronTransform.match(/matrix\([^,]+,[^,]+,[^,]+,[^,]+,[^,]+,([^\)]+)\)/)?.[1] ?? "NaN")
          : undefined;
      const disc = getComputedStyle(element).backgroundColor;
      if (name === "send" && disc !== "rgba(0, 0, 0, 0)" && disc !== "transparent")
        parts.push({ kind: "disc", left: rect.left, right: rect.right });
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
      return [{ name, box: { left: rect.left, right: rect.right }, parts, chevronY }];
    });
    controls.sort((a, b) => a.box.left - b.box.left);
    return {
      bar: { left: barRect.left, right: barRect.right },
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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.composer-row&variant=${variant}&theme=${encodeURIComponent(scheme === "light" ? "Apple System Colors Light" : "Apple System Colors")}`;

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
    await warm.goto(stageURL("queued", "light"));
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

  /** A running Claude chat with a prompt typed, so Interrupt, the mic and Send all show. */
  const row = async (width: number, scheme: string) => {
    const page = await browser!.newPage({ viewport: { width, height: 300 } });
    await page.goto(stageURL("queued", scheme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-effort .acpmux-picker-button").waitFor();
    await page.locator(".acpmux-composer-box [contenteditable='true'], .acpmux-composer-box textarea").first().click();
    await page.keyboard.type("Also cover the 503 path");
    await page.locator(".acpmux-steer").waitFor();
    await page.evaluate(() => document.fonts.ready);
    // Let the row's fit pass (composerRowFit.ts) settle after the typed text.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const measured = await page.evaluate(measure);
    await page.close();
    return measured;
  };

  const GROUPS = [["plus"], ["model", "effort"], ["mode", "plan"], ["steer", "mic", "send"]];
  const group = (name: string) => GROUPS.findIndex((members) => members.includes(name));
  const drawn = (control: Control): Span => ({
    left: control.parts[0]?.left ?? control.box.left,
    right: control.parts.at(-1)?.right ?? control.box.right,
  });

  for (const width of [760, 600, 480, 420])
    for (const scheme of ["light", "dark"])
      test(`at ${width} px (${scheme}): one gap in a group, one between groups, Send at the edge`, async () => {
        const measured = await row(width, scheme);
        const { controls } = measured;
        const names = controls.map((control) => control.name);
        const inGroup: { between: string; gap: number }[] = [];
        const betweenGroups: { between: string; gap: number }[] = [];
        for (let index = 1; index < controls.length; index++) {
          const before = controls[index - 1]!;
          const after = controls[index]!;
          // The row's free space sits between the leading groups and the trailing cluster.
          if (group(after.name) === 3 && group(before.name) !== 3) continue;
          const gap = { between: `${before.name}→${after.name}`, gap: drawn(after).left - drawn(before).right };
          (group(before.name) === group(after.name) ? inGroup : betweenGroups).push(gap);
        }
        // Inside each chip: the text's inset from the leading and trailing edges, and the space
        // between an icon or chevron and the text.
        const insides = controls
          .filter((control) => ["model", "effort", "mode", "plan", "steer"].includes(control.name))
          .map((control) => {
            const { parts, box } = control;
            const gaps = parts.slice(1).map((part, index) => part.left - parts[index]!.right);
            return {
              name: control.name,
              lead: parts[0] ? parts[0].left - box.left : 0,
              trail: parts.at(-1) ? box.right - parts.at(-1)!.right : 0,
              // Leading icon to text, and text to chevron, where the chip draws them.
              iconGap: parts[0]?.kind === "icon" && parts[1]?.kind === "text" ? gaps[0] : undefined,
              chevronGap: parts.at(-1)?.kind === "icon" && parts.at(-2)?.kind === "text" ? gaps.at(-1) : undefined,
              shape: parts.map((part) => part.kind).join("+"),
            };
          });
        const send = controls.find((control) => control.name === "send");
        console.log(
          JSON.stringify({
            width,
            scheme,
            names,
            barEdges: {
              lead: controls[0] ? drawn(controls[0]).left - measured.bar.left : undefined,
              trail: send ? measured.bar.right - drawn(send).right : undefined,
              padding: [measured.content.left - measured.bar.left, measured.bar.right - measured.content.right],
            },
            boxGaps: controls
              .slice(1)
              .map(
                (control, index) =>
                  `${controls[index]!.name}→${control.name} ${(control.box.left - controls[index]!.box.right).toFixed(1)}`,
              ),
            inGroup: inGroup.map(({ between, gap }) => `${between} ${gap.toFixed(1)}`),
            betweenGroups: betweenGroups.map(({ between, gap }) => `${between} ${gap.toFixed(1)}`),
            insides,
          }),
        );
        const problems: string[] = [];
        // The effort chip and the mic may leave a short row (or fold into the model chip); the
        // rest always shows.
        for (const name of ["plus", "model", "mode", "steer", "send"])
          if (!names.includes(name)) problems.push(`${name} is not in the row`);
        const spread = (values: number[]) => (values.length > 1 ? Math.max(...values) - Math.min(...values) : 0);
        const list = (gaps: { between: string; gap: number }[]) =>
          gaps.map(({ between, gap }) => `${between} ${gap.toFixed(1)}`).join(", ");
        if (spread(inGroup.map(({ gap }) => gap)) > 1) problems.push(`uneven gaps inside groups: ${list(inGroup)}`);
        if (spread(betweenGroups.map(({ gap }) => gap)) > 1)
          problems.push(`uneven gaps between groups: ${list(betweenGroups)}`);
        const tight = Math.max(...inGroup.map(({ gap }) => gap));
        for (const { between, gap } of betweenGroups)
          if (gap <= tight + 1) problems.push(`${between} ${gap.toFixed(1)} is not wider than the in-group gap`);
        for (const key of ["lead", "trail", "iconGap", "chevronGap"] as const) {
          const values = insides.flatMap((inside) => (inside[key] === undefined ? [] : [inside[key]!]));
          if (spread(values) > 1)
            problems.push(
              `chips' ${key} differs: ${insides.map((inside) => `${inside.name} ${inside[key]?.toFixed(1) ?? "-"}`).join(", ")}`,
            );
        }
        // Location and composer pickers share the same optical correction for their down-chevron.
        for (const control of controls.filter(({ name }) => ["model", "effort", "mode"].includes(name))) {
          if (control.chevronY === undefined || Math.abs(control.chevronY - 0.75) > 0.05)
            problems.push(`${control.name} chevron transform is ${control.chevronY ?? "missing"}, expected 0.75`);
        }
        // The + glyph and Send's disc sit the same distance from the bar's sides.
        const lead = controls[0] ? drawn(controls[0]).left - measured.bar.left : 0;
        const trail = send ? measured.bar.right - drawn(send).right : 0;
        if (Math.abs(lead - trail) > 1)
          problems.push(`the row's drawn edges differ: ${lead.toFixed(1)} px leading, ${trail.toFixed(1)} px trailing`);
        if (send && Math.abs(send.box.right - measured.content.right) > 1)
          problems.push(
            `Send ends ${(measured.content.right - send.box.right).toFixed(1)} px before the bar's content edge`,
          );
        expect(problems).toEqual([]);
      });
});
