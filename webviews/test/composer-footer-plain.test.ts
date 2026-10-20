// The composer footer's plain look (Debug Settings > Pages > "Agent composer: plain footer", the host's
// `composer` event `plainFooter`, composerSettings.ts): the Claude Code desktop footer, text at rest.
// Neither look draws a pill at rest (Leo 2026-10-19: the Claude app's chips). The plain look takes
// the rest of the difference away:
//   - the model's name is muted like effort and the permission mode;
//   - the model's brand mark and the mode's lock are hidden (each comes back when the row's fit
//     steps take the model's name or the mode's label away, so no chip is a bare chevron).
//     Chevrons stay.
// No chip draws a fill, ring or border at rest; hover, keyboard focus and an open menu draw the
// row's wash. Labels and keyboard behavior are the same; widths may shrink with the icons hidden,
// but the row's controls never overlap.
//
// It renders the real composer (the gallery's `agent-pane.composer-row` entry, `claude-auto`: Claude
// Opus 5.5, Medium, Auto) in Chromium at three pane widths, light and dark, and turns the look off and on
// through the host's own entry point (window.cmuxAcpmuxComposer, the old host's `composer` script).
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Chip = {
  name: string;
  left: number;
  right: number;
  height: number;
  background: string;
  shadow: string;
  border: string;
  color: string;
  /** The chip's label text, shown or stepped down. */
  label: string;
  /** Whether a leading icon (the model's mark, the mode's lock) draws. */
  leadingIcon: boolean;
  chevron: boolean;
  /** The model's name color. */
  nameColor?: string;
};
type Row = {
  /** Whether the model's name (any form) and the mode's label draw: the row's fit steps
   *  (composerRowFit.ts, data-fit-<unit> and the composer's container queries) take them away. */
  modelLabel: boolean;
  accessLabel: boolean;
  look: string;
  content: { left: number; right: number };
  chips: Chip[];
  boxes: Chip[];
};

await requireBrowserLane("composer-footer-plain.test.ts", async () => {
  /** Runs in the page: the footer's chips and every control's box. */
  function measure(): Row {
    const bar = document.querySelector<HTMLElement>(".acpmux-composer-bar")!;
    const shown = (element: Element) => {
      for (let node: Element | null = element; node && node !== bar; node = node.parentElement) {
        const css = getComputedStyle(node);
        if (css.display === "none" || css.visibility !== "visible") return false;
      }
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const read = (name: string, selector: string): Chip[] => {
      const element = bar.querySelector<HTMLElement>(selector);
      if (!element || !shown(element)) return [];
      const css = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      const icons = [...element.querySelectorAll("svg")];
      const chevron = icons.at(-1);
      const leading = icons.find((icon) => icon !== chevron);
      // The model's name as drawn: its full name, or the family form once the row steps it down.
      const modelName =
        [...element.querySelectorAll(".acpmux-model-name, .acpmux-model-short")].find(shown) ??
        element.querySelector(".acpmux-model-name");
      return [
        {
          name,
          left: rect.left,
          right: rect.right,
          height: rect.height,
          background: css.backgroundColor,
          shadow: css.boxShadow,
          border: css.borderTopWidth,
          color: css.color,
          label: [...element.querySelectorAll("span")].map((span) => span.textContent?.trim() ?? "").join(" "),
          leadingIcon: !!leading && shown(leading),
          chevron: !!chevron && shown(chevron),
          ...(modelName ? { nameColor: getComputedStyle(modelName).color } : {}),
        },
      ];
    };
    const style = getComputedStyle(bar);
    const barRect = bar.getBoundingClientRect();
    const chips = [
      ...read("model", ".acpmux-model .acpmux-picker-button"),
      ...read("effort", ".acpmux-effort .acpmux-picker-button"),
      ...read("mode", ".acpmux-access-trigger"),
    ];
    const boxes = [
      ...read("plus", ".acpmux-composer-plus .acpmux-picker-button"),
      ...chips,
      ...read("mic", ".acpmux-mic"),
      ...read("send", ".acpmux-send"),
    ].sort((a, b) => a.left - b.left);
    return {
      modelLabel: [...bar.querySelectorAll('.acpmux-model [data-fit-part="model"]')].some(shown),
      accessLabel: [...bar.querySelectorAll('.acpmux-access-trigger [data-fit-part="access"]')].some(shown),
      look: bar.dataset.footerLook ?? "",
      content: {
        left: barRect.left + parseFloat(style.paddingLeft),
        right: barRect.right - parseFloat(style.paddingRight),
      },
      chips,
      boxes,
    };
  }

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-footer-plain: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer footer plain look", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.composer-row&variant=claude-auto&theme=${encodeURIComponent(scheme === "light" ? "Apple System Colors Light" : "Apple System Colors")}`;

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
    await warm.goto(stageURL("light"));
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

  /** Two frames, then every running transition done (the pills ease their background). */
  const settle = (page: Page) =>
    page.evaluate(async () => {
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      const finite = document
        .getAnimations()
        .filter((animation) => Number.isFinite(Number(animation.effect?.getComputedTiming().endTime)));
      await Promise.all(finite.map((animation) => animation.finished.catch(() => undefined)));
    });

  /** The composer row; reduced motion, so a hover or the look applies at once. */
  const open = async (width: number, scheme: string) => {
    const page = await browser!.newPage({ viewport: { width, height: 300 }, reducedMotion: "reduce" });
    await page.goto(stageURL(scheme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-effort .acpmux-picker-button").waitFor();
    await page.evaluate(() => document.fonts.ready);
    await settle(page);
    return page;
  };
  /** The host's `composer` event, as the old host's script delivers it. */
  const plain = async (page: Page, on: boolean) => {
    await page.evaluate((value) => window.cmuxAcpmuxComposer?.({ plainFooter: value }), on);
    await settle(page);
  };

  const CLEAR = "rgba(0, 0, 0, 0)";
  const chip = (row: Row, name: string) => row.chips.find((each) => each.name === name);
  /** No control overlaps the next, and all sit inside the bar's content box. */
  const overlaps = (row: Row) => {
    const problems: string[] = [];
    row.boxes.forEach((box, index) => {
      const next = row.boxes[index + 1];
      if (next && box.right > next.left + 0.5)
        problems.push(`${box.name} overlaps ${next.name} by ${(box.right - next.left).toFixed(1)} px`);
      if (box.left < row.content.left - 0.5 || box.right > row.content.right + 0.5)
        problems.push(`${box.name} leaves the bar's content box`);
    });
    return problems;
  };

  for (const width of [760, 480, 340])
    for (const scheme of ["light", "dark"]) {
      test(`at ${width} px (${scheme}): plain by default; off, the chips draw as before`, async () => {
        const page = await open(width, scheme);
        // The plain look is the default (#22050, DEFAULT_COMPOSER.plainFooter); the host's
        // `composer` event turns it off.
        const initial = await page.evaluate(measure);
        await plain(page, false);
        const row = await page.evaluate(measure);
        await page.close();
        console.log(
          JSON.stringify({
            width,
            scheme,
            look: "off",
            model: row.modelLabel,
            access: row.accessLabel,
            chips: row.chips,
          }),
        );
        expect(initial.look).toBe("plain");
        expect(row.look).toBe("");
        const model = chip(row, "model")!;
        expect(model.leadingIcon).toBe(true);
        expect(model.nameColor).not.toBe(chip(row, "effort")!.color);
        expect(chip(row, "mode")!.leadingIcon).toBe(true);
        // No pill at rest in the default look either: the label and chevron only.
        for (const each of row.chips) {
          expect({ name: each.name, background: each.background }).toEqual({ name: each.name, background: CLEAR });
          expect(each.chevron).toBe(true);
        }
        expect(overlaps(row)).toEqual([]);
      });

      test(`at ${width} px (${scheme}): on, plain text at rest, same labels, no overlap`, async () => {
        const page = await open(width, scheme);
        await plain(page, false);
        const before = await page.evaluate(measure);
        await plain(page, true);
        const row = await page.evaluate(measure);
        await plain(page, false);
        const back = await page.evaluate(measure);
        await page.close();
        console.log(
          JSON.stringify({
            width,
            scheme,
            look: "on",
            model: row.modelLabel,
            access: row.accessLabel,
            chips: row.chips,
          }),
        );
        const problems: string[] = [];
        if (row.look !== "plain") problems.push(`the bar's look is "${row.look}", not "plain"`);
        for (const each of row.chips) {
          if (each.background !== CLEAR) problems.push(`${each.name} has a fill at rest: ${each.background}`);
          if (each.shadow !== "none") problems.push(`${each.name} has a ring at rest: ${each.shadow}`);
          if (each.border !== "0px") problems.push(`${each.name} has a border at rest: ${each.border}`);
          const was = chip(before, each.name);
          if (was?.label !== each.label) problems.push(`${each.name}'s label changed: ${was?.label} → ${each.label}`);
          if (was && Math.abs(was.height - each.height) > 0.5) problems.push(`${each.name}'s height changed`);
          if (!each.chevron) problems.push(`${each.name} lost its chevron`);
        }
        const model = chip(row, "model");
        const muted = chip(row, "effort")?.color;
        if (model?.nameColor !== muted) problems.push(`the model name ${model?.nameColor} is not muted (${muted})`);
        if (row.modelLabel && model?.leadingIcon) problems.push("the model's brand mark still draws beside its name");
        if (!row.modelLabel && !model?.leadingIcon) problems.push("the stepped-down model chip has no mark");
        const mode = chip(row, "mode");
        if (row.accessLabel && mode?.leadingIcon) problems.push("the mode's lock still draws beside its label");
        if (!row.accessLabel && !mode?.leadingIcon) problems.push("the stepped-down mode chip has no lock");
        problems.push(...overlaps(row));
        if (back.look !== "" || JSON.stringify(back.chips) !== JSON.stringify(before.chips))
          problems.push("turning the look off does not draw the chips as before");
        expect(problems).toEqual([]);
      });

      test(`at ${width} px (${scheme}): on, hover, keyboard focus and an open menu draw the wash`, async () => {
        const page = await open(width, scheme);
        await plain(page, true);
        const wash = async (name: string) => (await page.evaluate(measure)).chips.find((each) => each.name === name)!;
        const problems: string[] = [];
        for (const [name, selector] of [
          ["model", ".acpmux-model .acpmux-picker-button"],
          ["effort", ".acpmux-effort .acpmux-picker-button"],
          ["mode", ".acpmux-access-trigger"],
        ] as const) {
          await page.hover(selector);
          await settle(page);
          if ((await wash(name)).background === CLEAR) problems.push(`${name} draws no wash on hover`);
          await page.mouse.move(1, 1);
          await settle(page);
        }
        // Keyboard focus: Tab from the + button reaches the model chip.
        await page.focus(".acpmux-composer-plus .acpmux-picker-button");
        await page.keyboard.press("Tab");
        await settle(page);
        const focused = await page.evaluate(() =>
          document.activeElement?.matches(".acpmux-model .acpmux-picker-button:focus-visible"),
        );
        if (!focused) problems.push("Tab from + does not give the model chip keyboard focus");
        else if ((await wash("model")).background === CLEAR) problems.push("model draws no wash with keyboard focus");
        // An open menu: the permission mode's.
        await page.click(".acpmux-access-trigger");
        await page.locator(".acpmux-access-trigger[aria-expanded='true']").waitFor();
        await page.mouse.move(1, 1);
        await settle(page);
        if ((await wash("mode")).background === CLEAR) problems.push("mode draws no wash while its menu is open");
        await page.keyboard.press("Escape");
        await page.close();
        expect(problems).toEqual([]);
      });
    }
});
