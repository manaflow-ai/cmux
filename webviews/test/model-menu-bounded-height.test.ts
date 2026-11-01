// cmux-web-test-timeout: 300
// Lawrence: "model picker too tall". The compact model menu and its submenus took Base UI's
// --available-height as their only cap, so a positioner that published no room, or more room than
// the window, left a 48-profile Account submenu running past the window's edge. Each compact menu
// is at most the room it has and at most the window less 16 px, never taller than its rows, and its
// list scrolls to the real last row while the search field, the rail and an agent update stay in
// view.
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
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: "normal", height: VIEWPORT.height, theme: "Apple System Colors" })}`;

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

  /** The variant at the short window, its play done: the model menu and its Account submenu open. */
  const open = async (engine: string, variant: string, availableHeight?: string): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: VIEWPORT });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
      timeout: 120_000,
    });
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady), "the gallery mounted").toBe("1");
    expect(
      await page.evaluate(() => window.cmuxGalleryPlayReport?.error),
      "the gallery play completed without a setup error",
    ).toBeUndefined();
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-quick-menu").length > 1);
    await installPaintedFrames(page);
    // The submenu's positioner publishes no height (`initial` makes the var() fall back) or too large a one.
    if (availableHeight)
      await page.addStyleTag({
        content: `.ui-positioner:has(.acpmux-quick-menu .acpmux-quick-item) { --available-height: ${availableHeight} !important; }`,
      });
    await atRest(page);
    return page;
  };

  type Box = { top: number; bottom: number; height: number };
  type Menu = {
    box: Box;
    /** The positioner's --available-height in px, NaN when it publishes none. */
    available: number;
    /** The bottom of the menu's content, unscrolled: its last child's bottom plus its bottom padding. */
    contentBottom: number;
    /** Whether a menu that clips (the railed one) cuts off a child: the search, the rail and list, an update footer. */
    childClipped: boolean;
    /** Fixed siblings of the scrolling layout remain inside the capped popup. */
    fixed: { search: boolean; footer: boolean; searchPresent: boolean; footerPresent: boolean };
    /** Each scrolling box, scrolled to its end: whether its last row is wholly inside it and the window. */
    scrollers: {
      rows: number;
      scrolls: boolean;
      lastRowShown: boolean;
      lastRow: string;
      profiles: number;
      lastProfile: string;
      lastProfileShown: boolean;
    }[];
    profiles: number;
  };

  /** The model menu and its submenu: their boxes, then each scrolled to its end. */
  const measure = (page: Page) =>
    page.evaluate((): Menu[] => {
      const box = (element: Element): Box => {
        const rect = element.getBoundingClientRect();
        return { top: rect.top, bottom: rect.bottom, height: rect.height };
      };
      // The model menu first, then the submenu that lists the profiles.
      const lists = (menu: HTMLElement) =>
        Number(menu.querySelector(".acpmux-quick-search, .acpmux-quick-rail") === null);
      const menus = [...document.querySelectorAll<HTMLElement>(".acpmux-quick-menu")];
      menus.sort((a, b) => lists(a) - lists(b));
      /** A node of `menu` itself, not of a submenu inside it. */
      const own = (menu: HTMLElement, node: Element) => node.closest(".acpmux-quick-menu") === menu;
      const shapes = menus.map((menu) => {
        const style = getComputedStyle(menu);
        const outer = box(menu);
        const children = [...menu.children].map(box).filter((child) => child.height > 0);
        const layout = menu.querySelector<HTMLElement>(":scope > .acpmux-quick-layout");
        const fixedChildren = layout ? children : [];
        const search = menu.querySelector<HTMLElement>(":scope > .acpmux-quick-search");
        const footer = menu.querySelector<HTMLElement>(":scope > .acpmux-quick-update");
        return {
          box: outer,
          available: Number.parseFloat(
            getComputedStyle(menu.closest(".ui-positioner")!).getPropertyValue("--available-height"),
          ),
          contentBottom: Math.max(...children.map((child) => child.bottom)) + Number.parseFloat(style.paddingBottom),
          childClipped:
            !!layout &&
            /hidden|clip/.test(style.overflowY) &&
            fixedChildren.some((child) => child.top < outer.top - 0.5 || child.bottom > outer.bottom + 0.5),
          fixed: {
            search: !search || (box(search).top >= outer.top - 0.5 && box(search).bottom <= outer.bottom + 0.5),
            footer: !footer || (box(footer).top >= outer.top - 0.5 && box(footer).bottom <= outer.bottom + 0.5),
            searchPresent: search !== null,
            footerPresent: footer !== null,
          },
          profiles: lists(menu)
            ? Math.max(0, menu.querySelectorAll('[role="menuitemradio"]:not(.acpmux-quick-route)').length - 1)
            : 0,
        };
      });
      return menus.map((menu, index) => {
        const scrollers = [menu, ...menu.querySelectorAll<HTMLElement>("*")].filter(
          (node) =>
            own(menu, node) &&
            /auto|scroll/.test(getComputedStyle(node).overflowY) &&
            node.querySelector('[role^="menuitem"]') !== null &&
            !node.closest("[inert]"),
        );
        return {
          ...shapes[index]!,
          scrollers: scrollers.map((scroller) => {
            scroller.scrollTop = scroller.scrollHeight;
            const rows = [...scroller.querySelectorAll<HTMLElement>('[role^="menuitem"]')].filter(
              (row) => own(menu, row) && !row.closest("[inert]") && box(row).height > 0,
            );
            // Family routes share Account with profiles. Exclude those routes and the first
            // account radio (the harness login), keeping all installed profiles.
            const profileRows = lists(menu)
              ? rows.filter((row) => row.matches('[role="menuitemradio"]:not(.acpmux-quick-route)')).slice(1)
              : [];
            const area = box(scroller);
            const shown = box(rows.at(-1)!);
            const lastProfile = profileRows.at(-1);
            // Account route rows follow the installed profiles. Prove the last ordinary row at
            // the scroll end, then bring the actual last profile into view separately.
            const shownInside = (candidate: Box | undefined) =>
              candidate !== undefined &&
              candidate.top >= area.top - 0.5 &&
              candidate.bottom <= area.bottom + 0.5 &&
              candidate.top >= -0.5 &&
              candidate.bottom <= window.innerHeight + 0.5;
            const lastRowShown = shownInside(shown);
            if (lastProfile) {
              const profileBox = box(lastProfile);
              if (profileBox.top < area.top) scroller.scrollTop -= area.top - profileBox.top;
              else if (profileBox.bottom > area.bottom) scroller.scrollTop += profileBox.bottom - area.bottom;
            }
            return {
              rows: rows.length,
              scrolls: scroller.scrollHeight > scroller.clientHeight + 1,
              lastRowShown,
              lastRow: rows.at(-1)!.textContent ?? "",
              profiles: profileRows.length,
              lastProfile: lastProfile?.textContent ?? "",
              lastProfileShown: shownInside(lastProfile ? box(lastProfile) : undefined),
            };
          }),
        };
      });
    });

  /** Every compact menu sits inside the window, is at most its room and the window's cap and no taller
   *  than its rows, cuts off none of its parts, and shows its last row. */
  const expectBounded = (menus: Menu[], cap: number) => {
    for (const [index, menu] of menus.entries()) {
      const name = index === 0 ? "the model menu" : "the Account submenu";
      expect(menu.box.height, `${name} is no taller than the window's cap`).toBeLessThanOrEqual(cap + 0.5);
      if (Number.isFinite(menu.available))
        expect(menu.box.height, `${name} is no taller than its room`).toBeLessThanOrEqual(menu.available + 0.5);
      expect(menu.box.bottom, `${name} is no taller than its rows`).toBeLessThanOrEqual(menu.contentBottom + 1);
      expect(menu.childClipped, `${name} cuts off none of its parts`).toBe(false);
      expect(menu.fixed.search, `${name} keeps its search field inside the popup`).toBe(true);
      expect(menu.fixed.footer, `${name} keeps its update footer inside the popup`).toBe(true);
      expect(menu.box.top, `${name} starts inside the window`).toBeGreaterThanOrEqual(-0.5);
      expect(menu.box.bottom, `${name} ends inside the window`).toBeLessThanOrEqual(VIEWPORT.height + 0.5);
      for (const scroller of menu.scrollers)
        if (!Number.isFinite(menu.available) || menu.available >= 200)
          expect(scroller.lastRowShown, `${name} scrolls to its last row (${scroller.lastRow})`).toBe(true);
    }
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
        const menus = await measure(page);
        console.log(`::notice title=model-menu-bounded-height (${engine} ${label})::${JSON.stringify(menus)}`);
        await shoot(page, `${shot}-end`);
        expect(menus.length, "the model menu and its Account submenu are open").toBe(2);
        const [main, account] = menus as [Menu, Menu];
        if (override === undefined)
          expect(Number.isFinite(account.available), "Base UI publishes a finite available height").toBe(true);
        expect(account.profiles, "all 48 profiles are listed, not folded away").toBe(48);
        expect(account.scrollers.length, "the Account submenu scrolls on its own").toBeGreaterThan(0);
        const profileScroller = account.scrollers.find((scroller) => scroller.profiles === 48);
        expect(profileScroller, "the profile rows share a scrolling box").toBeDefined();
        expect(profileScroller!.lastProfile).toContain("Claude account 48");
        expect(profileScroller!.lastProfileShown, "the real last profile is visible after scrolling").toBe(true);
        expect(account.scrollers.some((scroller) => scroller.scrolls)).toBe(true);
        expect(main.scrollers.length, "the model list scrolls on its own").toBeGreaterThan(0);
        expect(main.fixed.searchPresent, "the model search is present").toBe(true);
        expect(main.fixed.footerPresent, "the landed update footer is present").toBe(true);
        expect(main.fixed.footer, "the landed update footer is a fixed sibling").toBe(true);
        expectBounded(menus, VIEWPORT.height - 16);
        await page.close();
      });
    }

    test(`${engine}: a short Account list is as tall as its rows`, async () => {
      const page = await open(engine, FEW);
      await shoot(page, `${engine}-${FEW}-open`);
      const menus = await measure(page);
      console.log(`::notice title=model-menu-bounded-height (${engine} short list)::${JSON.stringify(menus)}`);
      expect(menus.length).toBe(2);
      const account = menus[1]!;
      expect(account.profiles).toBeGreaterThan(1);
      expect(
        account.scrollers.every((scroller) => !scroller.scrolls),
        "the short list does not scroll",
      ).toBe(true);
      expect(account.box.bottom, "no room under its last row").toBeGreaterThanOrEqual(account.contentBottom - 1);
      expectBounded(menus, VIEWPORT.height - 16);
      await page.close();
    });
  }
});
