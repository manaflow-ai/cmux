// The New Tab page's machine menu and permission button, in Chromium on the gallery
// (agent-pane.new-tab-machine-menu). Leo, 2026-11-07: "this cloud button, like the machine
// selection button, this padding is awkward in that new tab area. It's, like, it's just not
// centered"; "I can't click to adjust the bypass permissions button there in that new tab screen";
// and "Sign in for Cloud" showing and then vanishing as the menu opened.
// - Geometry: every Where row's highlight is inset the same from the menu's two edges (5 px,
//   design/menus.md), and the machine button's content sits evenly in its pill.
// - Click: a real pointer click at the permission button's center reaches the button and opens its
//   menu (nothing over it eats the click).
// - Rows: the Where menu's first rows are its settled rows, signed in, signed out, and opened before
//   the app's Cloud answer; Cloud and Sign in for Cloud never show together.
// Numbers land in webviews/artifacts/newtab-machine-menu/.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("newtab-machine-menu.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.new-tab-machine-menu";
  const THEME = "Apple System Colors";
  const webviews = path.resolve(import.meta.dir, "..");
  const outDir = path.join(webviews, "artifacts", "newtab-machine-menu");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const log: string[] = [];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "closed" } });
    mkdirSync(outDir, { recursive: true });
  });
  afterAll(async () => {
    if (log.length) writeFileSync(path.join(outDir, "measured.tsv"), `${log.join("\n")}\n`);
    console.log(`newtab-machine-menu\n${log.join("\n")}`);
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, width: number, settle = true): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 420 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, theme: THEME })}`);
    if (settle) {
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
        timeout: 60_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    }
    return page;
  };

  const whereRows = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll('.acpmux-env-popover [role="option"]')].map(
        (row) => row.querySelector(".acpmux-menu-label")?.textContent ?? row.textContent ?? "",
      ),
    );

  for (const width of [760, 430])
    test(`Where menu rows at ${width}px: the highlight is inset evenly from both edges`, async () => {
      const page = await open("where", width);
      try {
        const m = await page.evaluate(() => {
          const popup = document.querySelector(".acpmux-env-popover")!.getBoundingClientRect();
          const rows = [...document.querySelectorAll<HTMLElement>('.acpmux-env-popover [role="option"]')].map((row) => {
            const rect = row.getBoundingClientRect();
            const icon = row.querySelector("svg")?.getBoundingClientRect();
            return {
              left: rect.left - popup.left,
              right: popup.right - rect.right,
              iconLeft: icon ? icon.left - popup.left : null,
            };
          });
          const list = document.querySelector(".acpmux-env-popover .acpmux-location-folders");
          return {
            width: popup.width,
            rows,
            scrollLeft: list?.scrollLeft ?? null,
            scrollWidth: list?.scrollWidth ?? null,
            clientWidth: list?.clientWidth ?? null,
          };
        });
        log.push(["where", width, JSON.stringify(m)].join("\t"));
        await page.screenshot({ path: path.join(outDir, `where-${width}.png`) }).catch(() => {});
        expect(m.rows.length).toBeGreaterThan(0);
        for (const row of m.rows) {
          expect(Math.abs(row.left - row.right)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(row.left - 5)).toBeLessThanOrEqual(0.5);
        }
      } finally {
        await page.close();
      }
    });

  test("the machine button's content sits evenly in its pill", async () => {
    const page = await open("closed", 760);
    try {
      const m = await page.evaluate((selector) => {
        const button = document.querySelector<HTMLElement>(selector)!;
        const rect = button.getBoundingClientRect();
        const kids = [...button.children].map((child) => child.getBoundingClientRect()).filter((r) => r.width > 0);
        const first = kids[0]!;
        const last = kids[kids.length - 1]!;
        // A glyph's ink sits inside its box: the chevron's 4 px bearing (--ui-ghost-end-bearing).
        const style = getComputedStyle(button);
        return {
          lead: first.left - rect.left,
          trail: rect.right - last.right,
          paddingLeft: style.paddingLeft,
          paddingRight: style.paddingRight,
          height: rect.height,
          contentTop: Math.min(...kids.map((r) => r.top)) - rect.top,
          contentBottom: rect.bottom - Math.max(...kids.map((r) => r.bottom)),
        };
      }, '.nt-location .acpmux-location-picker[data-kind="computer"][data-rows="where"] button');
      log.push(["button", 760, JSON.stringify(m)].join("\t"));
      expect(Math.abs(m.contentTop - m.contentBottom)).toBeLessThanOrEqual(0.5);
    } finally {
      await page.close();
    }
  });

  // #37858: a leaving row's whole box collapses, padding included, so its last frame is 0 tall and
  // its removal moves nothing (Leo, 2026-11-07: "some sort of nice, comfortable transition").
  test("a leaving row's last frame is 0 tall, padding included", async () => {
    const page = await open("where", 760);
    try {
      const m = await page.evaluate(() => {
        const item = document.querySelector<HTMLElement>('.acpmux-env-popover [role="option"]')!;
        const before = item.getBoundingClientRect().height;
        item.querySelector<HTMLElement>(".acpmux-env-row")!.dataset.rowMotion = "leave";
        const animations = item.getAnimations();
        for (const animation of animations) {
          animation.pause();
          const end = animation.effect?.getComputedTiming().endTime;
          animation.currentTime = typeof end === "number" ? end : 0;
        }
        const style = getComputedStyle(item);
        return {
          before,
          animations: animations.length,
          last: item.getBoundingClientRect().height,
          paddingTop: style.paddingTop,
          paddingBottom: style.paddingBottom,
        };
      });
      log.push(["leave-last-frame", JSON.stringify(m)].join("\t"));
      expect(m.before).toBeGreaterThan(0);
      expect(m.animations).toBeGreaterThan(0);
      expect(m.last).toBe(0);
      expect(m.paddingTop).toBe("0px");
      expect(m.paddingBottom).toBe("0px");
    } finally {
      await page.close();
    }
  });

  test("a pointer click on the permission button opens its menu", async () => {
    const page = await open("closed", 760);
    try {
      const hit = await page.evaluate(() => {
        const trigger = document.querySelector<HTMLElement>(".nt-foot .acpmux-access-trigger")!;
        const rect = trigger.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const top = document.elementFromPoint(x, y);
        const describe = (element: Element | null) =>
          element ? `${element.tagName.toLowerCase()}.${[...element.classList].join(".")}` : "none";
        return {
          x,
          y,
          tag: trigger.tagName.toLowerCase(),
          role: trigger.getAttribute("role"),
          ariaHidden: trigger.closest("[aria-hidden='true']") !== null,
          top: describe(top),
          reaches: top !== null && trigger.contains(top),
          pointerEvents: getComputedStyle(trigger).pointerEvents,
          chatNew:
            (window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions?.["chat.new"] !==
            undefined,
          chip: trigger.closest(".acpmux-mode")?.className ?? null,
        };
      });
      log.push(["permissions", 760, JSON.stringify(hit)].join("\t"));
      await page.mouse.click(hit.x, hit.y);
      const opened = await page
        .waitForSelector(".acpmux-access-menu", { timeout: 3_000 })
        .then(() => true)
        .catch(() => false);
      log.push(["permissions-opened", 760, String(opened)].join("\t"));
      expect(hit.reaches).toBe(true);
      expect(opened).toBe(true);
    } finally {
      await page.close();
    }
  });

  for (const variant of ["where", "where-signed-out"])
    test(`${variant}: the menu's first rows are its settled rows, with one Cloud row`, async () => {
      const page = await open(variant, 760);
      try {
        const first = await whereRows(page);
        // fixed-wait: the behavior is that nothing changes after the open; there is no event to wait for.
        await page.waitForTimeout(800);
        const settled = await whereRows(page);
        log.push([variant, "rows", JSON.stringify(first), JSON.stringify(settled)].join("\t"));
        expect(first).toEqual(settled);
        expect(first.filter((label) => /cloud/i.test(label)).length).toBe(1);
      } finally {
        await page.close();
      }
    });

  test("a signed-out answer that lands while Where is open changes the Cloud row in place", async () => {
    const page = await open("where-signed-out-late", 760, false);
    try {
      await page.waitForSelector('.acpmux-env-popover [role="option"]', { timeout: 60_000 });
      const height = () =>
        page.evaluate(() => document.querySelector(".acpmux-env-popover")!.getBoundingClientRect().height);
      const first = await whereRows(page);
      const before = await height();
      await page.waitForFunction(
        () =>
          [...document.querySelectorAll('.acpmux-env-popover [role="option"] .acpmux-menu-label')].some(
            (label) => label.textContent === "Sign in for Cloud",
          ),
        undefined,
        { timeout: 10_000 },
      );
      const settled = await whereRows(page);
      log.push(
        ["where-signed-out-late", "rows", JSON.stringify(first), JSON.stringify(settled), before, await height()].join(
          "\t",
        ),
      );
      expect(first).toEqual(["This Mac", "Cloud", "Remote"]);
      expect(settled).toEqual(["This Mac", "Sign in for Cloud", "Remote"]);
      expect(await height()).toBe(before);
    } finally {
      await page.close();
    }
  });

  test("opened before the app's Cloud answer, the Where menu draws its settled rows", async () => {
    const page = await open("where-slow-account", 760, false);
    try {
      await page.waitForSelector('.acpmux-env-popover [role="option"]', { timeout: 60_000 });
      const first = await whereRows(page);
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
        timeout: 60_000,
      });
      // fixed-wait: past the fixture's 1.5 s Cloud answer; the behavior is that the rows do not change.
      await page.waitForTimeout(2_000);
      const settled = await whereRows(page);
      log.push(["where-slow-account", "rows", JSON.stringify(first), JSON.stringify(settled)].join("\t"));
      expect(first).toEqual(settled);
    } finally {
      await page.close();
    }
  });
});
