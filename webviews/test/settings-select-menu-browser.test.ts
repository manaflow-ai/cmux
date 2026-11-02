// cmux-web-test-timeout: 1200
// l10n-allow-file: browser test diagnostics, not shipped UI.
// Leo 2026-10-30, on Settings > Updates with the Update Channel menu open: "look for wastage".
// Real Chromium and WebKit lay out the settings gallery's Updates page with its Update Channel menu
// open and hold the menu to the settings menu rule (leo-workspace design/settings.md): it hugs its
// rows and lines up with its trigger (left edge on the trigger's to 1px, never narrower), its rows are
// the menu row token (--ds-control-row), a select's checkmark sits on the AppKit state column with the
// text right after it (design/grid.md 5.3: state 10, text 22 when no row has an icon, never an empty
// icon gutter), the glass is never opaque, and the page title above it is not clipped. Check Every
// reads in hours, not seconds. With FAST_CHECKS_OUT set it also writes the 2x stills of the view.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { categories } from "../src/pages/settings/categories";
import { loadEntrySources } from "../scripts/gallery/entries";
import { measureMenus, menuFindings } from "./support/menuGeometry";

await requireBrowserLane("settings-select-menu-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    try {
      await (await engine.launch({ headless: true, timeout: 30_000 })).close();
      engines.push([name, engine]);
    } catch {
      console.warn(`settings-select-menu: ${name} cannot launch here; skipping it`);
    }
  }
  if (engines.length === 0) {
    describe.skip("settings select menu", () => test("browsers", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "pages.settings", { params: { variant: "updates" } });
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    if (out) await mkdir(out, { recursive: true });
  }, 200_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Box = { left: number; top: number; right: number; bottom: number; width: number; height: number };
  type Measured = {
    trigger: Box;
    popup: Box;
    rows: number[];
    checkCenter: number;
    textLeft: number[];
    rowToken: number;
    background: string;
    backdrop: string;
    title: { top: number; bottom: number; clipTop: number } | null;
    interval: { value: string; unit: string } | null;
  };

  async function measure(engine: string, colorScheme: "light" | "dark", capture: boolean): Promise<Measured> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({
      viewport: { width: 900, height: 640 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    try {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("pages.settings", { variant: "updates", colorScheme, width: 900, height: 640 })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
      expect(await page.locator("html").getAttribute("data-gallery-ready")).toBe("1");
      const trigger = page.locator('[data-row-key="updates.channel"] .ui-select-button');
      await trigger.scrollIntoViewIfNeeded();
      // A real pointer press, as a person opens it.
      await trigger.click();
      await page.waitForSelector(".ui-select-popup .ui-menu-item");
      await page.mouse.move(2, 2);
      const measured = await page.evaluate(() => {
        const box = (el: Element): Box => {
          const r = el.getBoundingClientRect();
          return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
        };
        const button = document.querySelector('[data-row-key="updates.channel"] .ui-select-button')!;
        const popup = document.querySelector(".ui-select-popup")!;
        const items = [...popup.querySelectorAll(".ui-menu-item")];
        const checked = popup.querySelector('.ui-menu-item[aria-checked="true"] .ui-menu-check')!;
        const checkBox = box(checked);
        const textLeft = items.map((item) => {
          const walker = document.createTreeWalker(item, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!node.textContent?.trim() || node.parentElement?.closest(".ui-menu-check")) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            return range.getBoundingClientRect().left - popup.getBoundingClientRect().left;
          }
          return Number.NaN;
        });
        const probe = document.createElement("div");
        probe.style.height = "var(--ds-control-row)";
        document.body.append(probe);
        const rowToken = probe.getBoundingClientRect().height;
        probe.remove();
        const style = getComputedStyle(popup);
        const heading = document.querySelector(".section-title");
        let title: Measured["title"] = null;
        if (heading) {
          // The nearest box that clips the heading: a scroller or the viewport.
          let clipTop = 0;
          for (let el = heading.parentElement; el; el = el.parentElement) {
            const overflow = getComputedStyle(el).overflowY;
            if (overflow !== "visible") clipTop = Math.max(clipTop, el.getBoundingClientRect().top);
          }
          const r = heading.getBoundingClientRect();
          title = { top: r.top, bottom: r.bottom, clipTop };
        }
        const field = document.querySelector<HTMLInputElement>(
          '[data-row-key="updates.checkIntervalSeconds"] input.field.number',
        );
        const unit = document.querySelector('[data-row-key="updates.checkIntervalSeconds"] .unit');
        return {
          trigger: box(button),
          popup: box(popup),
          rows: items.map((item) => item.getBoundingClientRect().height),
          checkCenter: checkBox.left + checkBox.width / 2 - box(popup).left,
          textLeft,
          rowToken,
          background: style.backgroundColor,
          backdrop: style.getPropertyValue("backdrop-filter") || style.getPropertyValue("-webkit-backdrop-filter"),
          title,
          interval: field ? { value: field.value || field.placeholder, unit: unit?.textContent ?? "" } : null,
        };
      });
      if (capture && out) {
        await page.screenshot({ path: path.join(out, `settings-updates-channel-${colorScheme}-${engine}.png`) });
        console.log(`settings-select-menu ${engine} ${colorScheme}: ${JSON.stringify(measured)}`);
      }
      return measured;
    } finally {
      await page.close();
    }
  }

  for (const [engine] of engines)
    for (const colorScheme of ["light", "dark"] as const)
      test(`${engine} ${colorScheme}: the Update Channel menu hugs and aligns with its trigger`, async () => {
        const m = await measure(engine, colorScheme, true);
        // Aligned: the menu's left edge on the trigger's, and at least as wide.
        expect(Math.abs(m.popup.left - m.trigger.left)).toBeLessThanOrEqual(1);
        expect(m.popup.width).toBeGreaterThanOrEqual(m.trigger.width - 0.5);
        // Rows on the menu row token.
        expect(m.rows.length).toBe(4);
        for (const height of m.rows) expect(Math.abs(height - m.rowToken)).toBeLessThanOrEqual(0.5);
        // The checkmark on the state column, the text right after it: no empty gutter.
        expect(Math.abs(m.checkCenter - 10)).toBeLessThanOrEqual(1);
        for (const left of m.textLeft) expect(Math.abs(left - 22)).toBeLessThanOrEqual(1);
        // Glass, never opaque: a translucent fill (under the surface roles' near-opaque 0.9) over a
        // frost strong enough that the row under it does not read through (the menu glass tokens).
        const alpha = Number(/\/\s*([\d.]+)\)\s*$|,\s*([\d.]+)\)\s*$/.exec(m.background)?.slice(1).find(Boolean) ?? 1);
        expect(alpha).toBeLessThan(0.9);
        expect(alpha).toBeGreaterThanOrEqual(0.75);
        expect(Number(/blur\((\d+)px\)/.exec(m.backdrop)?.[1] ?? 0)).toBeGreaterThanOrEqual(30);
        // The page title is whole: nothing clips its top.
        expect(m.title).not.toBeNull();
        expect(m.title!.top).toBeGreaterThanOrEqual(m.title!.clipTop - 0.5);
        // Check Every in hours: the default hour reads "1 hr", never "3600 s".
        expect(m.interval).toEqual({ value: "1", unit: "hr" });
      });

  // The same rule for every select on every Settings page: each opens at its trigger's left edge,
  // never narrower, on the menu row token, with its text at 22 (design/settings.md, "Menus").
  test("every Settings select menu hugs and aligns with its trigger", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const [engine] = engines[0]!;
    const page = await browsers
      .get(engine)!
      .newPage({ viewport: { width: 900, height: 640 }, reducedMotion: "reduce" });
    const failures: string[] = [];
    const shifted: string[] = [];
    let opened = 0;
    try {
      for (const category of categories) {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("pages.settings", { variant: category.id, width: 900, height: 640 })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
        const triggers = page.locator(".ui-select-button:not(:disabled)");
        const count = await triggers.count();
        for (let index = 0; index < count; index++) {
          const trigger = triggers.nth(index);
          if (!(await trigger.isVisible())) continue;
          await trigger.scrollIntoViewIfNeeded();
          await trigger.click();
          const popup = page.locator(".ui-select-popup").last();
          await popup.locator(".ui-menu-item").first().waitFor();
          const m = await page.evaluate(() => {
            const popup = [...document.querySelectorAll(".ui-select-popup")].at(-1)!;
            const button = document.querySelector('.ui-select-button[aria-expanded="true"]')!;
            const p = popup.getBoundingClientRect();
            const probe = document.createElement("div");
            probe.style.height = "var(--ds-control-row)";
            document.body.append(probe);
            const token = probe.getBoundingClientRect().height;
            probe.remove();
            const items = [...popup.querySelectorAll(".ui-menu-item")];
            const textLeft = items.map((item) => {
              const walker = document.createTreeWalker(item, NodeFilter.SHOW_TEXT);
              for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                if (!node.textContent?.trim() || node.parentElement?.closest(".ui-menu-check, .ui-menu-shortcut"))
                  continue;
                const range = document.createRange();
                range.selectNodeContents(node);
                return range.getBoundingClientRect().left - p.left;
              }
              return 22;
            });
            const row = button.closest("[data-row-key]")?.getAttribute("data-row-key") ?? button.textContent ?? "";
            return {
              row,
              left: p.left - button.getBoundingClientRect().left,
              // A menu wider than the room right of its trigger (a long list of painting titles)
              // slides left to stay in the window, as an AppKit menu does: it ends at the edge.
              noRoom: button.getBoundingClientRect().left + p.width > window.innerWidth - 4,
              narrower: button.getBoundingClientRect().width - p.width,
              rows: items.map((item) => item.getBoundingClientRect().height).filter((h) => Math.abs(h - token) > 0.5),
              text: textLeft.filter((left) => Math.abs(left - 22) > 1),
            };
          });
          opened++;
          const where = `${category.id} ${m.row}`;
          if (m.noRoom) shifted.push(where);
          else if (Math.abs(m.left) > 1) failures.push(`${where}: menu starts ${m.left.toFixed(1)}px from its trigger`);
          if (m.narrower > 0.5) failures.push(`${where}: menu ${m.narrower.toFixed(1)}px narrower than its trigger`);
          if (m.rows.length) failures.push(`${where}: rows ${m.rows.join(", ")}px, not the menu row token`);
          if (m.text.length) failures.push(`${where}: text at ${m.text.map((x) => x.toFixed(1)).join(", ")}, not 22`);
          await page.keyboard.press("Escape");
          await page.locator(".ui-select-popup").waitFor({ state: "detached" });
        }
      }
    } finally {
      await page.close();
    }
    console.log(
      `settings-select-menu: opened ${opened} Settings selects; ${failures.length} findings; ` +
        `shifted for room: ${shifted.join(", ") || "none"}`,
    );
    expect(opened).toBeGreaterThan(10);
    expect(failures).toEqual([]);
  }, 480_000);

  // Every menu, not only a select's (leo-workspace design/menus.md). Leo, 2026-10-22, on the
  // right-click menu: "THERE'S SO MUCH BULLSHIT PADDING AND WHATNOT LIKE ALL OVER THE FUCKIGN PLACE";
  // 2026-10-29: "misaligned checkmark :( can we all audit the checkmarks and whatnot". The menus this
  // rule was applied to are held to it in both engines, and their 2x stills are written for the PR;
  // every other *Menu*.gallery variant is opened and measured, and its findings are printed.
  const HELD: { entry: string; variant: string; still?: string }[] = [
    { entry: "ui.menu", variant: "open" },
    { entry: "ui.context-menu", variant: "open" },
    { entry: "ui.context-menu", variant: "mixed", still: "context-menu-mixed" },
    { entry: "pages.icon-picker", variant: "tone-menu", still: "icon-picker-tone" },
    { entry: "agent-pane.options-menu", variant: "several-open", still: "agent-pane-options-menu" },
    { entry: "agent-pane.saved-environment-panel", variant: "ssh-host-open", still: "host-select" },
    { entry: "pages.history", variant: "context-menu", still: "history-page-menu" },
    { entry: "pages.settings", variant: "updates-channel-open" },
  ];

  async function openMenus(engine: string, entry: string, variant: string, colorScheme?: "light" | "dark") {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({
      viewport: { width: 900, height: 640 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme, width: 900, height: 640 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60_000 });
    if ((await page.locator("html").getAttribute("data-gallery-ready")) !== "1") {
      await page.close();
      return null;
    }
    // A variant that does not open its menu itself: its first menu trigger, as a person clicks it.
    if ((await page.locator('[role="menu"]').count()) === 0) {
      const trigger = page.locator('[aria-haspopup="menu"]:not(:disabled)').first();
      if (await trigger.count()) {
        await trigger.click().catch(() => undefined);
        await page.waitForSelector('[role="menu"] [role^="menuitem"]', { timeout: 3_000 }).catch(() => undefined);
      }
    }
    await page.mouse.move(2, 2);
    return page;
  }

  for (const [engine] of engines)
    test(`${engine}: the menus this rule covers hug, align and keep one text line`, async () => {
      const failures: string[] = [];
      for (const { entry, variant, still } of HELD)
        for (const colorScheme of still && out ? (["light", "dark"] as const) : ([undefined] as const)) {
          const page = await openMenus(engine, entry, variant, colorScheme);
          if (!page) {
            failures.push(`${entry}/${variant}: the stage did not mount`);
            continue;
          }
          try {
            const menus = await measureMenus(page);
            if (menus.length === 0) failures.push(`${entry}/${variant}: no menu opened`);
            for (const menu of menus) {
              const findings = menuFindings(menu);
              console.log(
                `menu-geometry ${engine} ${entry}/${variant} ${menu.name}: ` +
                  `text ${menu.rows.map((row) => row.textX?.toFixed(1)).join(",")} ` +
                  `check ${menu.rows.map((row) => row.checkX?.toFixed(1) ?? "-").join(",")} ` +
                  `rows ${menu.rows.map((row) => row.height.toFixed(1)).join(",")} ` +
                  `width ${menu.popup.width.toFixed(0)} alpha ${menu.alpha} blur ${menu.blur}` +
                  (menu.trigger
                    ? ` trigger ${menu.trigger.width.toFixed(0)}@${(menu.popup.left - menu.trigger.left).toFixed(1)}`
                    : "") +
                  (findings.length ? ` FINDINGS: ${findings.join("; ")}` : ""),
              );
              if (colorScheme !== "dark")
                failures.push(...findings.map((f) => `${entry}/${variant} ${menu.name}: ${f}`));
            }
            if (still && out && colorScheme)
              await page.screenshot({ path: path.join(out, `${still}-${colorScheme}-${engine}.png`) });
          } finally {
            await page.close();
          }
        }
      expect(failures).toEqual([]);
    }, 600_000);

  test("every other menu gallery variant is measured (report)", async () => {
    const [engine] = engines[0]!;
    const held = new Set(HELD.map(({ entry, variant }) => `${entry}/${variant}`));
    const sources = await loadEntrySources();
    const cases = sources
      .filter(({ entry, path: file }) => entry.host !== "native" && /Menu[^/]*\.gallery\.tsx?$/.test(file))
      .flatMap(({ entry }) => Object.keys(entry.variants).map((variant) => ({ entry: entry.id, variant })))
      .filter(({ entry, variant }) => !held.has(`${entry}/${variant}`));
    let measured = 0;
    let withFindings = 0;
    for (const { entry, variant } of cases) {
      const page = await openMenus(engine, entry, variant).catch(() => null);
      if (!page) continue;
      try {
        for (const menu of await measureMenus(page)) {
          measured++;
          const findings = menuFindings(menu);
          if (findings.length) withFindings++;
          console.log(`menu-report ${entry}/${variant} ${menu.name}: ${findings.join("; ") || "ok"}`);
        }
      } finally {
        await page.close();
      }
    }
    console.log(`menu-report: ${measured} menus in ${cases.length} variants; ${withFindings} with findings`);
    expect(cases.length).toBeGreaterThan(0);
  }, 900_000);
});
