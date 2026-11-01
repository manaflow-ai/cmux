// The composer's controls row uses one gap and equal insets, in both looks (Leo 2026-10-31: "WHY THE
// F*** IS THE SPACING F***ING SHIT", then "IN THE F***ING CODEX MODE F***ING COMPOSER", with
// Codex's own composer beside ours). What a person sees between two controls is the space between
// what each draws (its text and icons), so this measures ink, not hit boxes:
//   - every two neighbouring controls of a row stand one gap apart (within 1 px), except the row's
//     one flexible gap, which parts the leading group from the trailing one;
//   - the first control's ink stands as far off the box's leading side as the last control's off
//     its trailing side (within 1 px);
//   - every control's center stands on the row's one center line (within 1 px).
// Codex's look draws one row inside the box; Claude's draws + … mic · Send in the box (its insets
// and its trailing cluster checked here) and the quiet row under it. Both looks build their rows
// from the same tokens (composerLocation.css, the row's rhythm), so neither can drift on its own.
// leo-workspace design/composer.md: "the composer row uses one gap token and equal insets; no
// per-control margins".
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

type Ink = { name: string; left: number; right: number; cy: number };
type Row = { box: { left: number; right: number; bottom: number }; controls: Ink[]; unit: number };

await requireBrowserLane("composer-row-one-gap.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-row-one-gap", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "codex-chat" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Runs in the page: each shown control in `row` (inside `box`), as the ink it draws. */
  function measure([boxSelector, rowSelector]: [string, string]): Row | null {
    const box = document.querySelector<HTMLElement>(boxSelector);
    const row = box?.querySelector<HTMLElement>(rowSelector) ?? (box?.matches(rowSelector) ? box : null);
    if (!box || !row) return null;
    const named: [string, string][] = [
      ["plus", ".acpmux-composer-plus .acpmux-picker-button"],
      ["mode", ".acpmux-access-trigger, .acpmux-access .acpmux-picker-button"],
      ["ring", ".acpmux-context-ring"],
      ["model", ".acpmux-model .acpmux-picker-button"],
      ["stop", ".acpmux-cancel"],
      ["mic", ".acpmux-mic"],
      ["send", ".acpmux-send:not(.acpmux-cancel)"],
    ];
    const shown = (element: Element) => {
      for (let node: Element | null = element; node && node !== document.body; node = node.parentElement) {
        const css = getComputedStyle(node);
        if (css.display === "none" || css.visibility !== "visible" || css.opacity === "0") return false;
      }
      const r = element.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    const controls = named.flatMap(([name, selector]): Ink[] => {
      const element = [...row.querySelectorAll<HTMLElement>(selector)].find(shown);
      if (!element) return [];
      const hit = element.getBoundingClientRect();
      let left = Infinity;
      let right = -Infinity;
      const add = (l: number, r: number) => {
        // Ink a control clips (a label laid out of the row for the fit) draws only inside it.
        const a = Math.max(l, hit.left);
        const b = Math.min(r, hit.right);
        if (b - a <= 0) return;
        left = Math.min(left, a);
        right = Math.max(right, b);
      };
      const walk = (node: Node) => {
        if (node instanceof SVGSVGElement) {
          if (shown(node)) {
            const r = node.getBoundingClientRect();
            add(r.left, r.right);
          }
          return;
        }
        if (node.nodeType === Node.TEXT_NODE) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) return;
          const range = document.createRange();
          range.selectNodeContents(node);
          const r = range.getBoundingClientRect();
          add(r.left, r.right);
          return;
        }
        if (node instanceof HTMLElement) {
          if (!shown(node)) return;
          // A label drawn by a pseudo-element (content: attr(...)) has no text node of its own.
          const before = getComputedStyle(node, "::before").content;
          if (before && before !== "none" && before !== "normal" && before !== '""') {
            const r = node.getBoundingClientRect();
            add(r.left, r.right);
          }
          // A mark drawn as an image or a background (the model's agent mark).
          if (node.classList.contains("agent-mark") || node instanceof HTMLImageElement) {
            const r = node.getBoundingClientRect();
            add(r.left, r.right);
          }
        }
        for (const child of node.childNodes) walk(child);
      };
      walk(element);
      if (!Number.isFinite(left)) return [];
      return [{ name, left, right, cy: (hit.top + hit.bottom) / 2 }];
    });
    controls.sort((a, b) => a.left - b.left);
    const r = box.getBoundingClientRect();
    // The gap the tokens give: each control's inset on either side of the row's one gap.
    const tokens = getComputedStyle(row);
    const unit =
      2 * parseFloat(tokens.getPropertyValue("--acpmux-row-inset")) +
      parseFloat(tokens.getPropertyValue("--acpmux-row-group-gap"));
    return { box: { left: r.left, right: r.right, bottom: r.bottom }, controls, unit };
  }

  const open = async (url: string, width: number, ready: string) => {
    const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 2 });
    await page.goto(`http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}${url}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(ready);
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    await page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );
    return page;
  };

  /** The row's problems: uneven gaps (the widest one is the flexible gap), uneven insets, off-center. */
  const check = (name: string, row: Row | null, { insets = true, flex = true, unit = true } = {}) => {
    if (!row) return [`${name}: no row`];
    const { controls, box } = row;
    const problems: string[] = [];
    const gaps = controls.slice(1).map((control, index) => ({
      between: `${controls[index]!.name}→${control.name}`,
      gap: control.left - controls[index]!.right,
    }));
    const widest = flex && gaps.length ? Math.max(...gaps.map(({ gap }) => gap)) : Infinity;
    const fixed = gaps.filter(({ gap }) => gap !== widest);
    const list = fixed.map(({ between, gap }) => `${between} ${gap.toFixed(1)}`).join(", ");
    const values = fixed.map(({ gap }) => gap);
    if (values.length > 1 && Math.max(...values) - Math.min(...values) > 1) problems.push(`${name}: uneven gaps: ${list}`);
    // And that gap is the tokens' (inset + group gap + inset), the same in every look's row.
    if (unit && values.some((gap) => Math.abs(gap - row.unit) > 1))
      problems.push(`${name}: gaps are not the tokens' ${row.unit.toFixed(1)} px: ${list}`);
    if (insets && controls.length) {
      const lead = controls[0]!.left - box.left;
      const trail = box.right - controls.at(-1)!.right;
      if (Math.abs(lead - trail) > 1)
        problems.push(
          `${name}: ${controls[0]!.name} stands ${lead.toFixed(1)} px off the leading side, ${controls.at(-1)!.name} ${trail.toFixed(1)} px off the trailing`,
        );
    }
    const axis = controls[0]?.cy ?? 0;
    for (const control of controls)
      if (Math.abs(control.cy - axis) > 1)
        problems.push(`${name}: ${control.name}'s center is ${(control.cy - axis).toFixed(1)} px off the row's`);
    console.log(`ROW_GEOMETRY ${name} ${JSON.stringify({ gaps, box, controls })}`);
    return problems;
  };

  for (const theme of ["light", "dark"])
    for (const width of [720, 480]) {
      test(`codex chat ${theme} ${width}: one gap between every control, equal insets, one center line`, async () => {
        const page = await open(
          galleryFrame("agent-pane.composer-look", {
            variant: "codex-chat",
            theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
          }),
          width,
          ".acpmux-composer[data-composer-look='codex'] .acpmux-model",
        );
        try {
          const row = await page.evaluate(measure, [".acpmux-composer-box", ".acpmux-composer-bar"] as [string, string]);
          expect(row?.controls.map(({ name }) => name)).toEqual(["plus", "mode", "ring", "model", "mic", "send"]);
          const problems = check(`codex chat ${width}`, row);
          // The row's center line stands as far over the box's bottom as +'s glyph center stands in
          // from its left, as Codex's does (Leo 2026-10-30: "why are the buttons so high up").
          const plus = row?.controls[0];
          if (row && plus) {
            const side = (plus.left + plus.right) / 2 - row.box.left;
            const bottom = row.box.bottom - plus.cy;
            if (Math.abs(side - bottom) > 1)
              problems.push(`the row's center stands ${bottom.toFixed(1)} px over the bottom, + ${side.toFixed(1)} px in`);
          }
          expect(problems).toEqual([]);
        } finally {
          await page.close();
        }
      });

      test(`claude chat ${theme} ${width}: the box row's insets match and its cluster keeps one gap`, async () => {
        const page = await open(
          galleryFrame("agent-pane.composer-look", {
            variant: "claude-chat",
            theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
          }),
          width,
          ".acpmux-composer-foot .acpmux-model",
        );
        try {
          // A draft brings Send in beside the mic, so the box's trailing cluster has two controls.
          await page.locator(".acpmux-composer-box [contenteditable='true'], .acpmux-composer-box textarea").first().click();
          await page.keyboard.type("Also cover the 503 path");
          await page.locator(".acpmux-composer-box .acpmux-send:not(.acpmux-cancel)").waitFor();
          await page.evaluate(
            () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
          );
          const inner = await page.evaluate(measure, [".acpmux-composer-box", ".acpmux-composer-bar"] as [
            string,
            string,
          ]);
          const foot = await page.evaluate(measure, [".acpmux-composer", ".acpmux-composer-foot"] as [string, string]);
          // The box's row: + on the left, the prompt between, the cluster on the right.
          const box: Row | null = inner && { ...inner, controls: inner.controls.filter(({ name }) => name !== "mode") };
          const problems = check(`claude box ${width}`, box);
          // The quiet row under the box keeps one gap between its controls; its column is the box's
          // (composer-alignment-centers.test.ts owns where it starts).
          problems.push(...check(`claude foot ${width}`, foot, { insets: false, unit: false }));
          expect(problems).toEqual([]);
        } finally {
          await page.close();
        }
      });
    }

  for (const width of [720, 480])
    test(`codex New Tab ${width}: one gap between every control, equal insets, one center line`, async () => {
      const tab = await (async () => {
        const context = await browser.newContext({ viewport: { width, height: 560 }, deviceScaleFactor: 2 });
        await context.addInitScript(() => localStorage.setItem("cmux.composer.look", "codex"));
        const p = await context.newPage();
        await p.goto(
          `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.new-tab", { variant: "minimal-default", width })}`,
        );
        await p.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await p.waitForSelector('.nt-composer[data-composer-look="codex"] .nt-box .nt-pickers .acpmux-model');
        await p.evaluate(() => document.fonts.ready);
        await p.evaluate(
          () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
        );
        return { p, context };
      })();
      try {
        const measured = await tab.p.evaluate(measure, [".nt-composer .nt-box", ".nt-pickers"] as [string, string]);
        // New Tab's insets are the page's own (newtab-input-scale.test.ts), and its mode chip's label
        // is fixed on its own (the clipped "s pern"); the model, the mic and Send keep the one gap.
        const row = measured && {
          ...measured,
          controls: measured.controls.filter(({ name }) => ["model", "mic", "send"].includes(name)),
        };
        expect(row?.controls.map(({ name }) => name)).toEqual(["model", "mic", "send"]);
        // New Tab's +, mic and Send are one 28 px control (composer-plus-geometry.test.ts), so Send's
        // 18 px glyph stands 5 px in: the gaps are even, not the tokens' exact width.
        expect(check(`codex New Tab ${width}`, row, { insets: false, flex: false, unit: false })).toEqual([]);
      } finally {
        await tab.context.close();
      }
    });
});
