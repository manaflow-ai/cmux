// cmux-web-test-timeout: 600
// l10n-allow-file: browser test diagnostics, not shipped UI.
// Leo, 2026-10-28: "I feel like you guys could be doing more audits of the app"; on a list whose
// rows started at different x: "the alignment i feel like we might as well".
// Real Chromium lays out the Harnesses page (gallery `agent-pane.harnesses`) and every Settings page
// (gallery `pages.settings`) and holds their rows to one column rule (leo-workspace
// design/settings.md, "Columns"; design/grid.md rule 2): the rows of one list share one text column,
// one leading mark column and one trailing control edge, and a row's control centers on its label.
// A row's label sits one gap after its leading mark, and an account's buttons start on its title's
// column. Before: Settings > Accounts put a provider's or a machine's name 40 to 90 px past its mark
// (the row's free space split around the label), Spaces started an active space's title 122 px right
// of the others', and an account's buttons sat 40 px in whether or not the row had a mark.
// Before: the Harnesses page drew each harness's status ("Ready", "Signed out") as a padded card
// 18 px right of its name, as wide as its text, because the page's status line shared its class
// with the Session status card's root.
// With FAST_CHECKS_OUT set it writes 2x light and dark stills of every page it measures.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { categories } from "../src/pages/settings/categories";

await requireBrowserLane("settings-columns-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    console.warn("settings-columns: chromium cannot launch here; skipping");
    describe.skip("settings columns", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.harnesses", { browser, params: { variant: "hover" } });
    await warmGalleryFrame(vite, "pages.settings", { browser, params: { variant: "general" } });
    if (out) await mkdir(out, { recursive: true });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const origin = () => `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;

  async function open(
    entry: string,
    params: Record<string, string | number>,
    viewport: { width: number; height: number },
  ) {
    const page = await browser!.newPage({ viewport, deviceScaleFactor: out ? 2 : 1, reducedMotion: "reduce" });
    await page.goto(`${origin()}${galleryFrame(entry, params)}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.mouse.move(0, 0);
    await installInk(page);
    return page;
  }

  /** Gives the page `__ink(el)`: the left edge of an element's first painted glyph (its ink, not
   *  its padding box), or null. */
  const installInk = (page: Page) =>
    page.evaluate(() => {
      (window as unknown as { __ink: (el: Element | null) => number | null }).__ink = (el) => {
        if (!el) return null;
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const r = range.getBoundingClientRect();
          if (r.width > 0) return r.left;
        }
        return null;
      };
    });

  type HarnessRow = {
    id: string;
    name: number | null;
    detail: number | null;
    detailBox: { padLeft: number; background: string; shadow: string; marginLeft: number };
    mark: number | null;
    action: number | null;
    actionMid: number | null;
    rowMid: number;
  };

  async function measureHarnesses(page: Page) {
    return page.evaluate(() => {
      const ink = (window as unknown as { __ink: (el: Element | null) => number | null }).__ink;
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-harness-row")].map((row): HarnessRow => {
        const detail = row.querySelector(".acpmux-harness-detail, .acpmux-harness-text > :nth-child(2)")!;
        const style = getComputedStyle(detail);
        const mark = row.firstElementChild!.getBoundingClientRect();
        const action = row.querySelector(".acpmux-harness-action")?.getBoundingClientRect();
        const r = row.getBoundingClientRect();
        return {
          id: row.dataset.harnessRow ?? "",
          name: ink(row.querySelector(".acpmux-harness-name")),
          detail: ink(detail),
          detailBox: {
            padLeft: parseFloat(style.paddingLeft),
            marginLeft: parseFloat(style.marginLeft),
            background: style.backgroundColor,
            shadow: style.boxShadow,
          },
          mark: mark.left + mark.width / 2,
          action: action ? action.right : null,
          actionMid: action ? action.top + action.height / 2 : null,
          rowMid: r.top + r.height / 2,
        };
      });
      const custom = document.querySelector("[data-harness-custom]");
      return {
        rows,
        custom: custom
          ? {
              name: ink(custom.querySelector(".acpmux-harness-name")),
              detail: ink(custom.querySelector(".acpmux-harness-detail, :scope > :nth-child(2)")),
              right: custom.querySelector(".acpmux-harness-detail, :scope > :nth-child(2)")!.getBoundingClientRect()
                .right,
              limit: custom.getBoundingClientRect().right,
            }
          : null,
      };
    });
  }

  const spread = (values: (number | null)[]) => {
    const known = values.filter((value): value is number => value !== null);
    return known.length ? Math.max(...known) - Math.min(...known) : 0;
  };

  for (const colorScheme of ["light", "dark"] as const)
    for (const variant of ["hover", "update-offered"])
      test(`Harnesses (${variant}, ${colorScheme}): one text column, one mark column, one action edge`, async () => {
        const page = await open(
          "agent-pane.harnesses",
          { variant, colorScheme, width: 360, height: 420 },
          { width: 360, height: 420 },
        );
        try {
          await page.waitForSelector(".acpmux-harness-row .acpmux-harness-action");
          const m = await measureHarnesses(page);
          if (out) {
            await page.screenshot({ path: path.join(out, `harnesses-${variant}-${colorScheme}.png`) });
            console.log(`settings-columns harnesses ${variant} ${colorScheme}: ${JSON.stringify(m)}`);
          }
          expect(m.rows.length).toBeGreaterThan(3);
          for (const row of m.rows) {
            // The status line is a line of text under the name, never a card of its own.
            expect(row.detailBox.background).toMatch(/rgba\(0, 0, 0, 0\)|transparent/);
            expect(row.detailBox.shadow).toBe("none");
            expect(row.detailBox.padLeft).toBe(0);
            expect(row.detailBox.marginLeft).toBe(0);
            // The status starts on its name's column.
            expect(Math.abs(row.detail! - row.name!)).toBeLessThanOrEqual(0.5);
            // A row's action centers on the row.
            if (row.actionMid !== null) expect(Math.abs(row.actionMid - row.rowMid)).toBeLessThanOrEqual(0.5);
          }
          // Every row: one text column, one mark center line, one trailing action edge.
          expect(spread(m.rows.map((row) => row.name))).toBeLessThanOrEqual(0.5);
          expect(spread(m.rows.map((row) => row.mark))).toBeLessThanOrEqual(0.5);
          expect(spread(m.rows.map((row) => row.action))).toBeLessThanOrEqual(0.5);
          // Custom harness… is a row of the same list: its text on the rows' text column.
          expect(m.custom).not.toBeNull();
          expect(Math.abs(m.custom!.name! - m.rows[0]!.name!)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(m.custom!.detail! - m.rows[0]!.name!)).toBeLessThanOrEqual(0.5);
          // Its detail truncates inside the page's column instead of running past the window.
          expect(m.custom!.right).toBeLessThanOrEqual(m.custom!.limit + 0.5);
        } finally {
          await page.close();
        }
      });

  type CardReport = {
    page: string;
    card: string;
    rows: {
      key: string;
      text: number | null;
      mark: number | null;
      control: number | null;
      offset: number | null;
      /** How much wider than the row's gap the space between its leading mark and its label is. */
      lead: number | null;
      /** How far the row's body (an account's buttons) starts from its title's column. */
      body: number | null;
    }[];
  };

  /** Every card of rows on a Settings page: each row's text column, mark center, control end and
   *  how far its control's center sits from its label's. */
  async function measureSettings(page: Page, name: string): Promise<CardReport[]> {
    return page.evaluate((name) => {
      const ink = (window as unknown as { __ink: (el: Element | null) => number | null }).__ink;
      const visible = (el: Element) => {
        const r = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && style.visibility !== "hidden" && Number(style.opacity) > 0;
      };
      /** The control's visible parts, `display: contents` hosts flattened. */
      const parts = (control: Element): Element[] =>
        [...control.children].flatMap((child) =>
          getComputedStyle(child).display === "contents" ? parts(child) : [child],
        );
      return [...document.querySelectorAll(".rows")].flatMap((card, index) => {
        const title = card.closest(".group")?.querySelector(".group-title")?.textContent?.trim() ?? `card ${index + 1}`;
        const rows = [...card.querySelectorAll<HTMLElement>(":scope > .row, :scope > * > .row")]
          .filter((row) => !row.classList.contains("row-note") && visible(row))
          .map((row) => {
            const label = row.querySelector(".row-label");
            const control = row.querySelector(".row-control");
            const shown = control
              ? parts(control).filter(
                  (part) =>
                    // Reset has its own reserved accessory gutter; compare the editors themselves
                    // whether that accessory is hidden, enabled, or visible at the default.
                    visible(part) && !part.classList.contains("reset-slot"),
                )
              : [];
            const end = shown.length ? Math.max(...shown.map((part) => part.getBoundingClientRect().right)) : null;
            let offset: number | null = null;
            if (label && shown.length) {
              const l = label.getBoundingClientRect();
              const top = Math.min(...shown.map((part) => part.getBoundingClientRect().top));
              const bottom = Math.max(...shown.map((part) => part.getBoundingClientRect().bottom));
              // Only a control on the label's own line(s): a wrapped control sits under it.
              if (top < l.bottom) offset = (top + bottom) / 2 - (l.top + l.bottom) / 2;
            }
            const mark = row.querySelector(".accounts-mark, .host-avatar");
            const m = mark?.getBoundingClientRect();
            const main = label?.parentElement;
            let lead: number | null = null;
            const before = label?.previousElementSibling;
            if (main?.classList.contains("row-main") && before && visible(before))
              lead =
                label!.getBoundingClientRect().left -
                before.getBoundingClientRect().right -
                parseFloat(getComputedStyle(main).columnGap || "0");
            const title = ink(row.querySelector(".row-title") ?? label);
            const bodyPart = row.querySelector(":scope > .accounts-body > *");
            const body =
              bodyPart && title !== null && visible(bodyPart) ? bodyPart.getBoundingClientRect().left - title : null;
            return {
              key:
                row.dataset.rowKey ??
                row.dataset.harness ??
                row.querySelector(".row-title")?.textContent?.trim().slice(0, 40) ??
                "",
              text: title,
              mark: m && m.width ? m.left + m.width / 2 : null,
              control: end,
              offset,
              lead,
              body,
            };
          });
        return rows.length ? [{ page: name, card: title, rows }] : [];
      });
    }, name);
  }

  /** Every break of the column rule in a card, as `page / card: what (px)`. */
  function breaks(card: CardReport): string[] {
    const found: string[] = [];
    const where = `${card.page} / ${card.card}`;
    const text = spread(card.rows.map((row) => row.text));
    if (text > 0.5)
      found.push(
        `${where}: text column spreads ${text.toFixed(1)}px (${card.rows.map((r) => `${r.key}@${r.text?.toFixed(1)}`).join(", ")})`,
      );
    const marked = card.rows.filter((row) => row.mark !== null);
    if (marked.length > 1 && spread(marked.map((row) => row.mark)) > 0.5)
      found.push(`${where}: mark column spreads ${spread(marked.map((row) => row.mark)).toFixed(1)}px`);
    const control = spread(card.rows.map((row) => row.control));
    if (control > 0.5)
      found.push(
        `${where}: control edge spreads ${control.toFixed(1)}px (${card.rows.map((r) => `${r.key}@${r.control?.toFixed(1)}`).join(", ")})`,
      );
    for (const row of card.rows)
      if (row.offset !== null && Math.abs(row.offset) > 1)
        found.push(`${where}: ${row.key} control ${row.offset.toFixed(1)}px off its label's center`);
    for (const row of card.rows) {
      if (row.lead !== null && Math.abs(row.lead) > 0.5)
        found.push(`${where}: ${row.key} label ${row.lead.toFixed(1)}px past one gap from its mark`);
      if (row.body !== null && Math.abs(row.body) > 0.5)
        found.push(`${where}: ${row.key} body starts ${row.body.toFixed(1)}px from its title's column`);
    }
    return found;
  }

  for (const width of [446, 641, 1000])
    test(`Settings Reset keeps editor columns and its accessory gutter (${width}px)`, async () => {
      const page = await open(
        "pages.settings",
        { variant: "appearance", colorScheme: "light", width, height: 2400 },
        { width, height: 2400 },
      );
      try {
        for (const [key, value, alwaysShown] of [
          ["appearance.metrics.sidebarWidth", "280", false],
          ["appearance.metrics.chromeFontSize", "16", true],
        ] as const) {
          const row = page.locator(`[data-row-key="${key}"]`);
          const field = row.locator("input.number");
          const reset = row.locator(".reset-button");
          const originalValue = await field.inputValue();
          const geometry = () =>
            row.evaluate((row) => {
              const editor = row.querySelector(".number-editor")!.getBoundingClientRect();
              const slot = row.querySelector(".reset-slot")!.getBoundingClientRect();
              const button = row.querySelector(".reset-button")!.getBoundingClientRect();
              const control = row.querySelector(".row-control")!;
              const bounds = row.getBoundingClientRect();
              return {
                edge: editor.right,
                gap: slot.left - editor.right,
                expectedGap: parseFloat(getComputedStyle(control).columnGap),
                slot: { left: slot.left, right: slot.right, top: slot.top, bottom: slot.bottom },
                button: { left: button.left, right: button.right, top: button.top, bottom: button.bottom },
                row: { left: bounds.left, right: bounds.right, top: bounds.top, bottom: bounds.bottom },
              };
            });
          const baseline = await geometry();
          expect(await reset.getAttribute("aria-hidden")).toBe(alwaysShown ? null : "true");
          expect(await reset.isDisabled()).toBe(true);
          await field.fill(value);
          await field.press("Enter");
          await page.waitForFunction((key) => {
            const button = document.querySelector<HTMLButtonElement>(`[data-row-key="${key}"] .reset-button`);
            return button && !button.disabled && button.getAttribute("aria-hidden") !== "true";
          }, key);
          expect(await field.inputValue()).toBe(value);
          const customized = await geometry();
          await reset.click();
          await page.waitForFunction(
            (key) => document.querySelector<HTMLButtonElement>(`[data-row-key="${key}"] .reset-button`)?.disabled,
            key,
          );
          expect(await field.inputValue()).toBe(originalValue);
          expect(await reset.getAttribute("aria-hidden")).toBe(alwaysShown ? null : "true");
          const restored = await geometry();
          for (const state of [baseline, customized, restored]) {
            expect(Math.abs(state.edge - baseline.edge)).toBeLessThanOrEqual(0.5);
            expect(Math.abs(state.gap - state.expectedGap)).toBeLessThanOrEqual(0.5);
            expect(state.button.left).toBeGreaterThanOrEqual(state.slot.left - 0.5);
            expect(state.button.right).toBeLessThanOrEqual(state.row.right);
            expect(state.button.top).toBeGreaterThanOrEqual(state.row.top);
            expect(state.button.bottom).toBeLessThanOrEqual(state.row.bottom);
            expect(state.slot.left).toBeGreaterThanOrEqual(state.row.left);
            expect(state.slot.right).toBeLessThanOrEqual(state.row.right);
            expect(state.slot.top).toBeGreaterThanOrEqual(state.row.top);
            expect(state.slot.bottom).toBeLessThanOrEqual(state.row.bottom);
          }
          const neighborEdge = await page
            .locator('[data-row-key="appearance.metrics.columnGap"] .number-editor')
            .evaluate((editor) => editor.getBoundingClientRect().right);
          expect(Math.abs(restored.edge - neighborEdge)).toBeLessThanOrEqual(0.5);
        }
      } finally {
        await page.close();
      }
    });

  const pages = [...categories.map((category) => category.id), "agents-harnesses-registry"];
  /** The cards whose stills a PR shows, by page: the ones the rule changed. */
  const stills: Record<string, string[]> = {
    accounts: ['[data-card="accounts"]', '[data-card="machines"]'],
    general: ['[data-card="rooms"]'],
  };

  test("every Settings page: one text column, one gap after a mark, one control edge, controls centered", async () => {
    const found: string[] = [];
    let cards = 0;
    for (const variant of pages)
      for (const colorScheme of out ? (["light", "dark"] as const) : (["light"] as const)) {
        const page = await open(
          "pages.settings",
          { variant, colorScheme, width: 1000, height: 2400 },
          { width: 1000, height: 2400 },
        );
        try {
          const report = await measureSettings(page, variant);
          if (colorScheme === "light") {
            cards += report.length;
            for (const card of report) found.push(...breaks(card));
          }
          if (out) {
            await page.screenshot({ path: path.join(out, `settings-${variant}-${colorScheme}.png`) });
            for (const selector of stills[variant] ?? []) {
              const card = page.locator(selector).first();
              const name = /"([^"]+)"/.exec(selector)![1];
              if (await card.count())
                await card.screenshot({ path: path.join(out, `card-${name}-${colorScheme}.png`) });
            }
          }
        } finally {
          await page.close();
        }
      }
    console.log(`settings-columns: ${pages.length} pages, ${cards} cards, ${found.length} breaks`);
    for (const line of found) console.log(`settings-columns break: ${line}`);
    expect(cards).toBeGreaterThan(10);
    if (process.env.SETTINGS_COLUMNS_REPORT) return;
    expect(found).toEqual([]);
  }, 540_000);
});
