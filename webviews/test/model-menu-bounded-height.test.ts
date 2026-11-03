// cmux-web-test-timeout: 300
// Lawrence: "model picker too tall". The model popup is capped at 259px and the available room.
// Its rail, model list and settings scroll independently while search and update stay in view.
// The account avatar opens a card: its active account heads it, and its other accounts scroll
// to the real last row without running past the window or reserving an empty spacer.
// Real Chromium and WebKit (the app's engine) on the gallery stage at a short window. CI fails the
// file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/model-menu-bounded-height.test.ts
// CMUX_MODEL_MENU_SHOTS=DIR also saves each case's PNG there.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-menu-bounded-height.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`model menu bounded height: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length !== 2) {
    throw new Error(
      `model menu bounded height requires Chromium and WebKit; launched ${engines.map(([name]) => name).join(", ") || "none"}`,
    );
  }

  const ENTRY = "agent-pane.model-picker";
  const MANY = "quick-menu-many-profiles";
  const FEW = "started-chat-accounts";
  const VIEWPORT = { width: 760, height: 360 };
  const SHOTS = process.env.CMUX_MODEL_MENU_SHOTS;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (variant: string, height: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: "normal", height, theme: "Apple System Colors" })}`;

  beforeAll(async () => {
    if (SHOTS) mkdirSync(SHOTS, { recursive: true });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: [...browsers.values()][0], params: { variant: MANY } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** Lets running transitions finish, then two painted frames. */
  const atRest = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      for (let moving = finite(); moving.length > 0; moving = finite())
        await Promise.allSettled(moving.map((animation) => animation.finished));
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });

  /** The columns and their account card, after the gallery play opens both. */
  const open = async (
    engine: string,
    variant: string,
    availableHeight?: string,
    height = VIEWPORT.height,
  ): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { ...VIEWPORT, height } });
    await page.goto(stageURL(variant, height));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
      timeout: 120_000,
    });
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady), "the gallery mounted").toBe("1");
    expect(
      await page.evaluate(() => window.cmuxGalleryPlayReport?.error),
      "the gallery play completed without a setup error",
    ).toBeUndefined();
    await page.locator(".acpmux-cols-card [role=button]").first().waitFor();
    await installPaintedFrames(page);
    if (availableHeight)
      await page.addStyleTag({
        content: `.ui-positioner:has(.acpmux-cols) { --available-height: ${availableHeight} !important; }`,
      });
    await atRest(page);
    return page;
  };

  type Box = { top: number; bottom: number; height: number };

  /** Read the fixed parts, then scroll each column and the account list to its real last row. */
  const measure = (page: Page) =>
    page.evaluate(() => {
      const box = (element: Element): Box => {
        const rect = element.getBoundingClientRect();
        return { top: rect.top, bottom: rect.bottom, height: rect.height };
      };
      const inside = (child: Box, parent: Box) => child.top >= parent.top - 0.5 && child.bottom <= parent.bottom + 0.5;
      const inWindow = (child: Box) => inside(child, { top: 0, bottom: innerHeight, height: innerHeight });
      const popup = document.querySelector<HTMLElement>(".acpmux-cols")!;
      const frame = popup.querySelector<HTMLElement>(".acpmux-cols-frame")!;
      const body = frame.querySelector<HTMLElement>(".acpmux-cols-body")!;
      const search = frame.querySelector<HTMLElement>(".acpmux-cols-search")!;
      const footer = frame.querySelector<HTMLElement>(".acpmux-cols-update");
      const card = popup.querySelector<HTMLElement>(".acpmux-cols-card")!;
      const accountList = card.querySelector<HTMLElement>(".acpmux-cols-card-list:has(> .acpmux-cols-caption)")!;
      const accounts = [...accountList.querySelectorAll<HTMLElement>("[role=button]")];
      const names = accounts.map((row) => row.querySelector(".acpmux-cols-name")?.textContent ?? "");
      const scrollEnd = (list: HTMLElement, rows: HTMLElement[]) => {
        list.scrollTop = list.scrollHeight;
        const last = rows.at(-1)!;
        return {
          rows: rows.length,
          scrolls: list.scrollHeight > list.clientHeight + 1,
          lastRow: last.textContent ?? "",
          lastRowShown: inside(box(last), box(list)) && inWindow(box(last)),
        };
      };
      const frameBox = box(frame);
      const cardChildren = [...card.children].map(box).filter((child) => child.height > 0);
      return {
        windowHeight: innerHeight,
        popup: box(popup),
        frame: frameBox,
        available: Number.parseFloat(
          getComputedStyle(popup.closest(".ui-positioner")!).getPropertyValue("--available-height"),
        ),
        childClipped: [...frame.children].some((child) => !inside(box(child), frameBox)),
        search: inside(box(search), frameBox),
        footerPresent: !!footer,
        footer: !footer || inside(box(footer), frameBox),
        columns: [...body.querySelectorAll<HTMLElement>(":scope > .acpmux-cols-list")].map((list) => ({
          ...scrollEnd(list, [...list.querySelectorAll<HTMLElement>("[role]")]),
          box: box(list),
          overflow: getComputedStyle(list).overflowY,
          inside: inside(box(list), frameBox),
        })),
        account: {
          box: box(card),
          contentBottom: Math.max(...cardChildren.map((child) => child.bottom)),
          current: card.querySelector(".acpmux-cols-card-name")?.textContent ?? "",
          listHeight: box(accountList).height,
          contentHeight:
            [...accountList.children].reduce((height, child) => height + box(child).height, 0) +
            Number.parseFloat(getComputedStyle(accountList).paddingTop) +
            Number.parseFloat(getComputedStyle(accountList).paddingBottom),
          names,
          ...scrollEnd(accountList, accounts),
        },
      };
    });

  const expectBounded = (layout: Awaited<ReturnType<typeof measure>>) => {
    expect(layout.frame.height, "the columns keep their 259px cap").toBeLessThanOrEqual(259.5);
    if (Number.isFinite(layout.available))
      expect(layout.frame.height, "the columns fit their published room").toBeLessThanOrEqual(layout.available + 0.5);
    expect(layout.popup.top, "the popup starts inside the window").toBeGreaterThanOrEqual(-0.5);
    expect(layout.popup.bottom, "the popup ends inside the window").toBeLessThanOrEqual(layout.windowHeight + 0.5);
    expect(layout.childClipped, "none of the frame's fixed parts are clipped").toBe(false);
    expect(layout.search, "search stays visible above the scrolling columns").toBe(true);
    expect(layout.footer, "the update stays visible below the scrolling columns").toBe(true);
    expect(layout.columns, "rail, models and settings scroll independently").toHaveLength(3);
    for (const column of layout.columns) {
      expect(column.overflow).toMatch(/auto|scroll/);
      expect(column.inside, "the column is inside the frame").toBe(true);
      expect(column.rows, "the fixture exercises each column").toBeGreaterThan(0);
      expect(column.lastRowShown, `the column scrolls to its last row (${column.lastRow})`).toBe(true);
    }
    expect(layout.account.box.top, "the card starts inside the window").toBeGreaterThanOrEqual(-0.5);
    expect(layout.account.box.bottom, "the card ends inside the window").toBeLessThanOrEqual(layout.windowHeight + 0.5);
    expect(layout.account.box.height, "the card keeps to the window's cap").toBeLessThanOrEqual(
      layout.windowHeight - 15.5,
    );
    expect(layout.account.listHeight, "the account list is no taller than its content").toBeLessThanOrEqual(
      layout.account.contentHeight + 1,
    );
    expect(layout.account.box.bottom, "no empty space below the card's content").toBeLessThanOrEqual(
      layout.account.contentBottom + 1,
    );
    expect(layout.account.lastRowShown, "the last account is fully visible after scrolling").toBe(true);
  };

  /** The page as it stands (opened, or each list scrolled to its end), into CMUX_MODEL_MENU_SHOTS. */
  const shoot = async (page: Page, name: string) => {
    if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
  };

  for (const [engine] of engines) {
    for (const [label, override] of [
      ["the room Base UI publishes", undefined],
      ["a smaller published room", "120px"],
    ] as const) {
      test(`${engine}, ${label}: 48 profiles keep to the short window and scroll to the last one`, async () => {
        const page = await open(engine, MANY, override);
        const shot = `${engine}-${MANY}-${override ?? "published"}`;
        await shoot(page, `${shot}-open`);
        const layout = await measure(page);
        console.log(`::notice title=model-menu-bounded-height (${engine} ${label})::${JSON.stringify(layout)}`);
        await shoot(page, `${shot}-end`);
        if (override === undefined)
          expect(Number.isFinite(layout.available), "Base UI publishes a finite available height").toBe(true);
        // The active account heads the card; only the other 47 accounts are switching rows.
        expect(layout.account.current).toBe("Claude account 1");
        expect(layout.account.names.filter((name) => name.startsWith("Claude account "))).toHaveLength(47);
        expect(layout.account.lastRow).toContain("Claude account 48");
        expect(layout.account.scrolls, "the long account list scrolls inside the card").toBe(true);
        expect(layout.footerPresent, "the update footer is present").toBe(true);
        expectBounded(layout);
        await page.close();
      });
    }

    test(`${engine}: a short account card is as tall as its content`, async () => {
      // Leave room for the card's avatar header as well as its few switching rows.
      const page = await open(engine, FEW, undefined, 520);
      await shoot(page, `${engine}-${FEW}-open`);
      const layout = await measure(page);
      console.log(`::notice title=model-menu-bounded-height (${engine} short list)::${JSON.stringify(layout)}`);
      expect(layout.account.names).toContain("Anthropic API key");
      expect(layout.account.names.length).toBeGreaterThan(1);
      expect(layout.account.scrolls, "a short account list does not need to scroll").toBe(false);
      expect(layout.account.box.bottom, "no room under the card's last child").toBeGreaterThanOrEqual(
        layout.account.contentBottom - 1,
      );
      expectBounded(layout);
      await page.close();
    });
  }
});
