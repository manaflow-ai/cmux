// Real Chromium exercises the shipped picker through its single gallery fixture.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("quick-model-menu-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "new-tab.quick-model-menu", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, width = 640, height = 560, entry = "new-tab.quick-model-menu") {
    const page = await browser.newPage({ viewport: { width, height } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    return page;
  }

  const bounds = async (page: Page, selector: string) => (await page.locator(selector).boundingBox())!;

  test("More models grows with the viewport and shares one body scroll", async () => {
    const heights: number[] = [];
    for (const height of [400, 1000]) {
      const page = await open("opencode-more-models", 640, height);
      try {
        const menu = await bounds(page, ".acpmux-quick-menu");
        heights.push(menu.height);
        expect(menu.y + menu.height).toBeLessThanOrEqual(height);
        expect(await page.locator(".acpmux-quick-more-list").evaluate((node) => getComputedStyle(node).overflowY)).toBe(
          "visible",
        );
        await page.locator(".acpmux-quick-body").evaluate((node) => {
          node.scrollTop = node.scrollHeight;
        });
        await page.getByRole("menuitemradio", { name: /Sample Model 40/ }).waitFor();
      } finally {
        await page.close();
      }
    }
    expect(heights[1]!).toBeGreaterThan(480);
    expect(heights[1]!).toBeGreaterThan(heights[0]! + 200);
  });

  test("search and model rows share height and padding without a second list inset", async () => {
    for (const variant of ["claude-many-harnesses", "chat-flipped"]) {
      const page = await open(variant);
      try {
        const geometry = await page.evaluate(() => {
          const search = document.querySelector<HTMLElement>(".acpmux-quick-search")!;
          const item = document.querySelector<HTMLElement>(".acpmux-quick-item")!;
          const body = document.querySelector<HTMLElement>(".acpmux-quick-body")!;
          return {
            searchHeight: search.getBoundingClientRect().height,
            itemHeight: item.getBoundingClientRect().height,
            searchInset: getComputedStyle(search).paddingLeft,
            itemInset: getComputedStyle(item).paddingLeft,
            bodyInset: getComputedStyle(body).paddingLeft,
          };
        });
        expect(geometry.searchHeight).toBe(geometry.itemHeight);
        expect(geometry.searchInset).toBe(geometry.itemInset);
        expect(geometry.bodyInset).toBe("0px");
      } finally {
        await page.close();
      }
    }
  });

  test("downward Claude menu ends immediately after Fast even with ten distinct harnesses", async () => {
    const page = await open("claude-many-harnesses");
    try {
      const menu = await bounds(page, ".acpmux-quick-menu");
      const fast = await bounds(page, ".acpmux-quick-fast");
      const chip = await bounds(page, "button[data-menu=model]");
      expect(menu.y).toBeGreaterThan(chip.y);
      expect(menu.y + menu.height - fast.y - fast.height).toBeLessThan(12);
      // Ten harnesses and Add, less Claude Code (sr): a route of the Claude tab, never its own tab.
      expect(await page.locator(".acpmux-quick-rail-tab").count()).toBe(10);
      expect(await page.locator(".acpmux-quick-fast").innerText()).toBe("Fast mode");
      expect(await page.locator(".acpmux-quick-list").innerText()).toContain("Claude subscription");
    } finally {
      await page.close();
    }
  });

  test("harness controls keep their position while each direction follows visible content", async () => {
    for (const variant of ["claude-many-harnesses", "combined", "chat-flipped"]) {
      const page = await open(variant);
      try {
        const rail = await bounds(page, ".acpmux-quick-rail");
        const menu = await bounds(page, ".acpmux-quick-menu");
        await page.getByRole("button", { name: "Codex", exact: true }).click();
        await page.waitForFunction(
          () =>
            document.querySelector(".acpmux-quick-rail-tab[aria-pressed=true]")?.getAttribute("aria-label") === "Codex",
        );
        const nextRail = await bounds(page, ".acpmux-quick-rail");
        const nextMenu = await bounds(page, ".acpmux-quick-menu");
        expect(Math.abs(nextRail.x - rail.x)).toBeLessThan(1);
        expect(Math.abs(nextMenu.x - menu.x)).toBeLessThan(1);
        expect(nextMenu.width).toBe(menu.width);
        expect(nextMenu.height).toBeLessThan(menu.height);
        expect(await page.locator(".acpmux-quick-list").innerText()).toContain("GPT-6");
      } finally {
        await page.close();
      }
    }
  });

  test("inline effort controls keep a narrow railed menu inside the viewport when switching harnesses", async () => {
    const page = await open("claude-many-harnesses-inline-effort", 320, 560);
    try {
      await page
        .locator(".acpmux-quick-model-effort .acpmux-quick-effort-trigger")
        .first()
        .waitFor({ state: "attached" });
      const menu = await bounds(page, ".acpmux-quick-menu");
      const rail = await bounds(page, ".acpmux-quick-rail");
      await page.getByRole("button", { name: "Codex", exact: true }).click();
      await page.waitForFunction(
        () =>
          document.querySelector(".acpmux-quick-rail-tab[aria-pressed=true]")?.getAttribute("aria-label") === "Codex",
      );
      await page
        .locator(".acpmux-quick-model-effort .acpmux-quick-effort-trigger")
        .first()
        .waitFor({ state: "attached" });
      const switched = await bounds(page, ".acpmux-quick-menu");
      const switchedRail = await bounds(page, ".acpmux-quick-rail");
      expect(switched.width).toBeLessThanOrEqual(296);
      expect(switched.x + switched.width).toBeLessThanOrEqual(320);
      expect(Math.abs(switched.width - menu.width)).toBeLessThan(1);
      expect(Math.abs(switchedRail.x - rail.x)).toBeLessThan(1);
    } finally {
      await page.close();
    }
  });

  test("a midpoint menu keeps its opening side as tall content becomes short", async () => {
    const page = await open("newtab-midpoint");
    try {
      const menu = page.locator(".acpmux-quick-menu");
      await page.waitForFunction(
        () => document.querySelector(".acpmux-quick-menu")?.getAttribute("data-side") === "top",
      );
      const rail = await bounds(page, ".acpmux-quick-rail");
      await page.getByRole("button", { name: "Codex", exact: true }).click();
      await page.waitForFunction(
        () =>
          document.querySelector(".acpmux-quick-rail-tab[aria-pressed=true]")?.getAttribute("aria-label") === "Codex",
      );
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      expect(await menu.getAttribute("data-side")).toBe("top");
      expect(Math.abs((await bounds(page, ".acpmux-quick-rail")).x - rail.x)).toBeLessThan(1);
    } finally {
      await page.close();
    }
  });

  test("keyboard-selected harnesses stay visible in an overflowing strip", async () => {
    const page = await open("claude-many-harnesses", 320);
    try {
      await page.keyboard.press("ArrowLeft");
      const add = page.locator(".acpmux-quick-rail-add");
      expect(await add.evaluate((node) => node === document.activeElement)).toBe(true);
      await page.keyboard.press("ArrowLeft");
      const selected = page.locator(".acpmux-quick-rail-tab[aria-pressed=true]");
      await page.waitForFunction(
        () =>
          document.querySelector(".acpmux-quick-rail-tab[aria-pressed=true]")?.getAttribute("aria-label") === "Goose",
      );
      const button = (await selected.boundingBox())!;
      const rail = await bounds(page, ".acpmux-quick-rail");
      expect(button.x).toBeGreaterThanOrEqual(rail.x);
      expect(button.x + button.width).toBeLessThanOrEqual(rail.x + rail.width);
    } finally {
      await page.close();
    }
  });

  test("reopening a scrolled menu restores its first-row inset without a top fade", async () => {
    const page = await open("claude-many-harnesses", 320, 290);
    try {
      await page.locator(".acpmux-quick-body").evaluate((node) => {
        node.scrollTop = node.scrollHeight;
      });
      await page.waitForFunction(() => document.querySelector(".acpmux-quick-body")?.hasAttribute("data-scrolled"));
      await page.keyboard.press("Escape");
      await page.locator(".acpmux-quick-menu").waitFor({ state: "hidden" });
      await page.locator("button[data-menu=model]").click();
      await page.locator(".acpmux-quick-menu").waitFor();
      expect(await page.locator(".acpmux-quick-body").getAttribute("data-scrolled")).toBeNull();
      expect(await page.locator(".acpmux-quick-body").evaluate((node) => node.scrollTop)).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("launch configurations are named harness entries, with no Profile submenu", async () => {
    const page = await open("claude");
    try {
      expect(await page.getByRole("menuitem", { name: /^Profile/ }).count()).toBe(0);
      // A launch configuration of a family is a route in its Account row, never a tab of its own
      // (Leo 2026-10-31: "THE FUCKING APP SERVER THE FUCKING SR" / "WHERE IS THE FUCKING ACCOUNTS").
      expect(await page.getByRole("button", { name: "Claude Code (sr)", exact: true }).count()).toBe(0);
      await page.getByRole("menuitem", { name: /^Account/ }).hover();
      await page.getByRole("menuitemradio", { name: "Claude Code (sr)", exact: true }).waitFor();
      await page.getByRole("menuitemradio", { name: "API key", exact: true }).waitFor();
    } finally {
      await page.close();
    }
  });

  test("the picker opens with one row of harness symbols above the models", async () => {
    // Leo 2026-10-30: "honestly we had a pretty good thing going with teh symbols of the harneses
    // at the top :(".
    const page = await open("claude");
    try {
      const rail = await bounds(page, ".acpmux-quick-rail");
      const body = await bounds(page, ".acpmux-quick-body");
      expect(rail.y + rail.height).toBeLessThanOrEqual(body.y + 1);
      const tabs = page.locator(".acpmux-quick-rail-tab:not(.acpmux-quick-rail-add)");
      const boxes = await tabs.evaluateAll((nodes) => nodes.map((node) => node.getBoundingClientRect().toJSON()));
      // One row: every tab on the first tab's line.
      for (const box of boxes) expect(Math.abs(box.y - boxes[0].y)).toBeLessThan(1);
      // Every tab is its mark alone, never text (Leo 2026-10-31: "NOBODY FUCKING ASKED FOR THE
      // HARNESSES TO HAVE FUCKING LABELED FUCKING TEXT ON THEM THAT'S THE POINT"); its name is its
      // label and title. Drawn: a tab is as narrow as its mark (the picker's own rule hides the
      // name, not a Tailwind utility the page may lack).
      const allTabs = await tabs.evaluateAll((nodes) =>
        nodes.map((node) => ({
          hidden: !!node.querySelector(".acpmux-quick-harness-name.sr-only"),
          drawn: node.getBoundingClientRect().width > node.getBoundingClientRect().height * 1.5,
          mark: !!node.querySelector(".agent-mark, svg, .acpmux-quick-rail-initial"),
          label: node.getAttribute("aria-label"),
          title: node.getAttribute("title"),
        })),
      );
      expect(allTabs.length).toBeGreaterThan(1);
      for (const tab of allTabs) {
        expect(tab.hidden, `${tab.label}: its name is hidden on the tab`).toBe(true);
        expect(tab.drawn, `${tab.label}: text shows on the tab`).toBe(false);
        expect(tab.mark, `${tab.label}: no mark`).toBe(true);
        expect(tab.label).toBeTruthy();
        expect(tab.title).toBeTruthy();
      }
      expect(await page.locator(".acpmux-quick-rail .agent-mark-monogram").count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("the target picker: themed symbols on top, a star and ⌘N on each row, Legacy models", async () => {
    // Leo 2026-10-30: "we're going to go with the harness symbols at the top. like this, but symbols
    // at the top, and themed, and combined with the effort side dropdown inside it".
    const page = await open("claude");
    try {
      // Themed: the symbols draw in the text colour (no brand fill), the selected one lit.
      const fills = await page
        .locator(".acpmux-quick-rail-tab .agent-mark")
        .evaluateAll((nodes) => nodes.map((node) => node.getAttribute("fill")));
      expect(fills.length).toBeGreaterThan(0);
      expect(fills.every((fill) => fill === "currentColor")).toBe(true);
      const colors = await page.locator(".acpmux-quick-rail-tab:not(.acpmux-quick-rail-add)").evaluateAll((nodes) =>
        nodes.map((node) => ({
          on: node.getAttribute("aria-pressed") === "true",
          color: getComputedStyle(node).color,
        })),
      );
      const lit = colors.find((tab) => tab.on)!;
      expect(colors.filter((tab) => !tab.on).every((tab) => tab.color !== lit.color)).toBe(true);
      // A star on the starred row (Opus 5.5).
      expect(await page.locator(".acpmux-quick-star[aria-pressed=true]").count()).toBe(1);
      // A harness's other models sit under Legacy models with their count.
      expect(await page.getByText("Legacy models", { exact: true }).count()).toBe(1);
      expect(await page.getByText(/^5 models$/).count()).toBe(1);
    } finally {
      await page.close();
    }
    // ⌘N on the rows: in a chat's menu (New Tab's shows no key hints, as before).
    const chat = await open("combined");
    try {
      const keys = await chat.locator(".acpmux-quick-list .ui-menu-shortcut").allInnerTexts();
      expect(keys.length).toBeGreaterThan(0);
      expect(
        keys.every((key) => /^⌘[1-9]$/.test(key.trim())),
        keys.join(","),
      ).toBe(true);
    } finally {
      await chat.close();
    }
    // One right edge (Leo 2026-10-31: "plus all this dumbass shit in the model picker"): with each
    // row's effort item on, every ⌘N key and the running row's check share the menu's trailing
    // column, after the effort item and the star, never mid-row.
    const inChat = await open("in-chat");
    try {
      await inChat.locator(".acpmux-quick-model-effort[data-running]").first().waitFor();
      const edges = await inChat.locator(".acpmux-quick-model-effort").evaluateAll((rows) =>
        rows.map((row) => {
          const key = row.querySelector(
            ":scope > .ui-menu-item .ui-menu-shortcut, :scope > .ui-menu-item .ui-menu-check:not(:empty)",
          );
          const effort = row.querySelector(":scope > .acpmux-quick-effort-trigger");
          const star = row.querySelector(":scope > .acpmux-quick-star");
          const box = key?.getBoundingClientRect();
          return {
            right: box ? Math.round(box.right) : undefined,
            left: box?.left,
            effortRight: effort?.getBoundingClientRect().right,
            starRight: star?.getBoundingClientRect().right,
          };
        }),
      );
      const keyed = edges.filter((edge) => edge.right !== undefined);
      expect(keyed.length, JSON.stringify(edges)).toBeGreaterThan(1);
      expect(new Set(keyed.map((edge) => edge.right)).size, JSON.stringify(edges)).toBe(1);
      for (const edge of keyed) {
        if (edge.effortRight !== undefined) expect(edge.effortRight).toBeLessThanOrEqual(edge.left! + 0.5);
        if (edge.starRight !== undefined) expect(edge.starRight).toBeLessThanOrEqual(edge.left! + 0.5);
      }
    } finally {
      await inChat.close();
    }
  });

  test("many harnesses wrap into whole symbols, never one cut at the strip's edge", async () => {
    // Leo 2026-10-28: "don't have bullshit end halfway on a fucking icon when there's lots of harnesses".
    for (const width of [320, 640]) {
      const page = await open("harness-symbols-many", width);
      try {
        const rail = await bounds(page, ".acpmux-quick-rail");
        const tabs = await page
          .locator(".acpmux-quick-rail-tab")
          .evaluateAll((nodes) => nodes.map((node) => node.getBoundingClientRect().toJSON()));
        expect(tabs.length).toBeGreaterThan(8);
        // A tab the strip shows any of (more than a pixel) must be whole.
        const visible = tabs.filter((tab) => tab.y < rail.y + rail.height - 1 && tab.y + tab.height > rail.y + 1);
        for (const tab of visible) {
          expect(tab.x).toBeGreaterThanOrEqual(rail.x - 0.5);
          expect(tab.x + tab.width).toBeLessThanOrEqual(rail.x + rail.width + 0.5);
          expect(tab.y).toBeGreaterThanOrEqual(rail.y - 0.5);
          expect(tab.y + tab.height).toBeLessThanOrEqual(rail.y + rail.height + 0.5);
        }
      } finally {
        await page.close();
      }
    }
  });

  test("the picker uses native menu rows and a left harness rail", async () => {
    const page = await open("harness-left");
    try {
      const rail = await bounds(page, ".acpmux-quick-rail");
      const body = await bounds(page, ".acpmux-quick-body");
      const row = (await page.locator(".acpmux-quick-list .acpmux-quick-item").first().boundingBox())!;
      expect(rail.x + rail.width).toBeLessThanOrEqual(body.x + 1);
      // A native menu's row (Leo 2026-10-28: "AND I THINK IT'S ALL SO STUPIDLY SPACED AND STYLED
      // IT'S FUCKING TONKA TOYS").
      expect(Math.round(row.height)).toBe(28);
      const search = await bounds(page, ".acpmux-quick-search");
      expect(search.height).toBe(row.height);
      expect(await page.locator(".acpmux-quick-rail .agent-mark-monogram").count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("one row per model; effort is a vertical side dropdown beside the model, never a row of words", async () => {
    // The P0 wall (#26521 put every level under every model). Leo 2026-10-30: "we dont like
    // horizontal text for effort. just make it vertical. hell, why not do a vertical slider?".
    for (const [entry, variant, width] of [
      ["new-tab.quick-model-menu", "claude-many-harnesses-inline-effort", 640],
      ["agent-pane.inline-model-effort", "chat", 640],
      ["agent-pane.inline-model-effort", "chat", 1000],
    ] as const) {
      const page = await open(variant, width, 560, entry);
      try {
        await page.locator(".acpmux-quick-model-effort").first().waitFor();
        // Every model one 28 px row, and no level in the menu itself.
        const rows = await page
          .locator(".acpmux-quick-model-effort")
          .evaluateAll((nodes) => nodes.map((node) => Math.round(node.getBoundingClientRect().height)));
        expect(rows.length).toBeGreaterThan(1);
        expect(
          rows.every((height) => height === 28),
          `row heights ${rows.join(",")}`,
        ).toBe(true);
        expect(
          await page.locator(".acpmux-quick-menu:not(.acpmux-quick-effort-menu) .acpmux-quick-effort-segment").count(),
        ).toBe(0);
        // The keyboard reaches it: from the running model, Right on its effort item opens the levels.
        const row = page.locator(".acpmux-quick-model-effort[data-running]").first();
        const trigger = row.locator(".acpmux-quick-effort-trigger");
        await trigger.focus();
        await page.keyboard.press("ArrowRight");
        const dropdown = page.locator(".acpmux-quick-effort-menu");
        await dropdown.waitFor();
        const levels = dropdown.locator(".acpmux-quick-effort-segment");
        const boxes = await levels.evaluateAll((nodes) => nodes.map((node) => node.getBoundingClientRect().toJSON()));
        expect(boxes.length).toBeGreaterThan(1);
        // One under another, in a popup of its own beside the row, whole inside the window.
        for (let index = 1; index < boxes.length; index++) {
          expect(boxes[index].y).toBeGreaterThanOrEqual(boxes[index - 1].y + boxes[index - 1].height - 0.5);
          expect(Math.abs(boxes[index].x - boxes[0].x)).toBeLessThan(1);
        }
        // Beside the row's effort item, clear of the model's name (a starred row's star may follow
        // the effort item at the row's very end).
        const triggerBox = (await trigger.boundingBox())!;
        const nameBox = (await row
          .locator(":scope > .acpmux-quick-item:first-child > .acpmux-quick-label")
          .boundingBox())!;
        const menuBox = (await dropdown.boundingBox())!;
        const viewport = page.viewportSize()!;
        // Beside the effort item whenever the window has room on that side; a narrow window shifts it,
        // as every submenu of this menu (the shared Submenu's collision handling), and it stays whole.
        const geometry = `${variant}: name ${JSON.stringify(nameBox)} effort ${JSON.stringify(triggerBox)} dropdown ${JSON.stringify(menuBox)}`;
        if (viewport.width - (triggerBox.x + triggerBox.width) >= menuBox.width) {
          expect(menuBox.x, geometry).toBeGreaterThanOrEqual(triggerBox.x + triggerBox.width - 8);
          expect(menuBox.x, geometry).toBeGreaterThanOrEqual(nameBox.x + nameBox.width);
        }
        expect(menuBox.x).toBeGreaterThanOrEqual(0);
        expect(menuBox.x + menuBox.width).toBeLessThanOrEqual(viewport.width);
        expect(menuBox.y).toBeGreaterThanOrEqual(0);
        expect(menuBox.y + menuBox.height).toBeLessThanOrEqual(viewport.height);
        // Each level is one line: its name and any "Recommended" badge share the row (review of #27948).
        const lines = await levels.evaluateAll((nodes) =>
          nodes.map((node) => {
            const row = node.getBoundingClientRect();
            const parts = [...node.querySelectorAll<HTMLElement>(".acpmux-menu-label, .acpmux-quick-effort-badge")];
            return parts.every((part) => {
              const box = part.getBoundingClientRect();
              return box.top >= row.top - 0.5 && box.bottom <= row.bottom + 0.5;
            });
          }),
        );
        expect(lines.every(Boolean), `levels with a part outside their row: ${lines.join(",")}`).toBe(true);
        if (entry === "agent-pane.inline-model-effort")
          expect(
            await dropdown.locator(".acpmux-quick-effort-badge").count(),
            "the fixture's recommended level shows its badge",
          ).toBe(1);
        // The last level takes a click at its centre: nothing covers it.
        const last = boxes.at(-1)!;
        expect(
          await page.evaluate(([x, y]) => !!document.elementFromPoint(x, y)?.closest(".acpmux-quick-effort-menu"), [
            last.x + last.width / 2,
            last.y + last.height / 2,
          ] as const),
        ).toBe(true);
      } finally {
        await page.close();
      }
    }
  });

  test("the bottom model's effort dropdown is whole, and pointing at the next model leaves the first", async () => {
    // The chat fixture's model button sits 484px down (a composer at the window's foot), so the
    // window is tall enough to show it: a menu whose anchor is off screen is hidden with it.
    const page = await open("chat", 640, 560, "agent-pane.inline-model-effort");
    try {
      const rows = page.locator(".acpmux-quick-model-effort");
      const lastRow = rows.last();
      const lastTrigger = lastRow.locator(".acpmux-quick-effort-trigger");
      expect(
        await lastTrigger.isVisible(),
        await lastTrigger.evaluate((node) => {
          const rect = node.getBoundingClientRect();
          const hidden: string[] = [];
          for (let at: Element | null = node; at; at = at.parentElement) {
            const style = getComputedStyle(at);
            if (style.visibility !== "visible" || style.display === "none")
              hidden.push(`${at.className} ${style.visibility} ${style.display}`);
          }
          return `trigger ${JSON.stringify(rect.toJSON())} hidden by ${hidden.join(" | ")}`;
        }),
      ).toBe(true);
      await lastTrigger.hover();
      const dropdown = page.locator(".acpmux-quick-effort-menu");
      await dropdown.waitFor();
      const box = (await dropdown.boundingBox())!;
      expect(box.y + box.height).toBeLessThanOrEqual(page.viewportSize()!.height);
      // The first row's model takes the pointer and closes the dropdown it does not own. The pointer
      // travels there (a hover-opened submenu blocks the rows behind its safe path until the pointer
      // leaves it, so Playwright's hover() sees the menu's positioner on top and never moves).
      const first = (await rows.first().locator(":scope > .acpmux-quick-item:first-child").boundingBox())!;
      await page.mouse.move(first.x + first.width / 3, first.y + first.height / 2, { steps: 8 });
      await dropdown.waitFor({ state: "detached" });
    } finally {
      await page.close();
    }
  });

  test("inline effort keeps the compact rail at its narrow geometry", async () => {
    const page = await open("compact", 640, 560, "agent-pane.inline-model-effort");
    try {
      const rail = await bounds(page, ".acpmux-quick-rail");
      expect(rail.width).toBeGreaterThanOrEqual(76);
      expect(rail.width).toBeLessThan(110);
      expect(await page.locator(".acpmux-quick-effort-trigger").count()).toBeGreaterThan(0);
    } finally {
      await page.close();
    }
  });

  test("every harness placement leaves the model rows visible", async () => {
    for (const variant of [
      "harness-symbols",
      "harness-symbols-many",
      "harness-left",
      "harness-top",
      "harness-compact",
    ]) {
      const page = await open(variant, 420, 560);
      try {
        const body = await bounds(page, ".acpmux-quick-body");
        const first = (await page.locator(".acpmux-quick-list [role=menuitemradio]").first().boundingBox())!;
        expect(body.height).toBeGreaterThanOrEqual(first.height);
        expect(first.y).toBeGreaterThanOrEqual(body.y);
        expect(first.y + first.height).toBeLessThanOrEqual(body.y + body.height);
      } finally {
        await page.close();
      }
    }
  });

  test("a long account name keeps the Account control readable in a narrow pane", async () => {
    for (const width of [320, 420]) {
      const page = await open("claude", width);
      try {
        const label = page.getByRole("menuitem", { name: /^Account/ }).locator(".acpmux-menu-label");
        expect(await label.evaluate((node) => node.scrollWidth <= node.clientWidth)).toBe(true);
        await page.getByRole("menuitem", { name: /^Account/ }).hover();
        await page.getByRole("menuitemradio", { name: "API key", exact: true }).waitFor();
      } finally {
        await page.close();
      }
    }
  });

  test("searching from another family's tab selects the visible model", async () => {
    const page = await open("claude");
    try {
      await page.keyboard.press("ArrowLeft");
      expect(await page.locator(".acpmux-quick-rail-add").evaluate((node) => node === document.activeElement)).toBe(
        true,
      );
      await page.keyboard.press("ArrowLeft");
      await page.waitForFunction(
        () => document.querySelector('.acpmux-quick-rail-tab[aria-pressed="true"]')?.textContent === "OpenCode",
      );
      await page.locator(".acpmux-quick-search input").fill("Sonnet");
      await page.keyboard.press("Enter");
      expect(await page.locator("[data-selection]").getAttribute("data-selection")).toBe("claude/Sonnet 5.5");
    } finally {
      await page.close();
    }
  });

  test("Fast switch toggles with the keyboard and stays inside a narrow short window", async () => {
    const page = await open("claude-many-harnesses", 320, 290);
    try {
      const menu = await bounds(page, ".acpmux-quick-menu");
      expect(menu.x).toBeGreaterThanOrEqual(0);
      expect(menu.y).toBeGreaterThanOrEqual(0);
      expect(menu.x + menu.width).toBeLessThanOrEqual(320);
      expect(menu.y + menu.height).toBeLessThanOrEqual(290);
      const body = page.locator(".acpmux-quick-body");
      expect(await body.getAttribute("data-scrolled")).toBeNull();
      const first = (await page.locator(".acpmux-quick-list [role=menuitemradio]").first().boundingBox())!;
      const inset = await bounds(page, ".acpmux-quick-body");
      expect(first.y - inset.y).toBe(0);
      await body.evaluate((node) => {
        node.scrollTop = node.scrollHeight;
      });
      await page.waitForFunction(() => document.querySelector(".acpmux-quick-body")?.hasAttribute("data-scrolled"));
      const fast = page.getByRole("menuitemcheckbox", { name: "Fast mode", exact: true });
      await fast.focus();
      await page.keyboard.press("Space");
      expect(await fast.getAttribute("aria-checked")).toBe("true");
      await page.keyboard.press("Space");
      expect(await fast.getAttribute("aria-checked")).toBe("false");
      const track = await bounds(page, ".acpmux-quick-fast-toggle");
      expect(track.width).toBeGreaterThan(track.height);
    } finally {
      await page.close();
    }
  });

  test("the menu is as wide as the rows its tabs show; a long Legacy model never widens it", async () => {
    // Leo 2026-11-01: "i also don't like the way this composer has so much space between stuff
    // surely we can get more compact horizontally" / "see claude code has that".
    const widths: Record<string, number> = {};
    const gaps: Record<string, number> = {};
    for (const variant of ["width-stable", "width-wide"]) {
      const page = await open(variant, 900, 640);
      try {
        widths[variant] = (await bounds(page, ".acpmux-quick-menu")).width;
        {
          // The widest shown name to its row's ⌘N key: the band between them.
          gaps[variant] = await page.evaluate(() => {
            const gaps = [...document.querySelectorAll(".acpmux-quick-model-effort")].flatMap((row) => {
              const name = row.querySelector(".acpmux-menu-label")?.getBoundingClientRect();
              const key = row.querySelector(".ui-menu-shortcut")?.getBoundingClientRect();
              return name && key ? [key.left - name.right] : [];
            });
            return Math.min(...gaps);
          });
        }
      } finally {
        await page.close();
      }
    }
    expect(widths["width-stable"]!).toBeLessThan(widths["width-wide"]! - 40);
    // The band shrinks by the width the fixed menu added, so effort and ⌘N sit close to the name.
    expect(gaps["width-stable"]!).toBeLessThan(gaps["width-wide"]! - 60);
  });

  test("one tab per harness: Claude and Codex routes are Account choices, never tabs", async () => {
    // Leo 2026-11-01: "we have too many harnesses because you didn't put those things into
    // accounts or whatever".
    const page = await open("routes-one-tab");
    try {
      const marks = await page
        .locator(".acpmux-quick-rail-tab:not(.acpmux-quick-rail-add)")
        .evaluateAll((tabs) => tabs.map((tab) => tab.getAttribute("aria-label")));
      expect(marks.filter((name) => /claude/i.test(name ?? ""))).toHaveLength(1);
      expect(marks.filter((name) => /codex/i.test(name ?? ""))).toHaveLength(1);
      await page.getByRole("menuitem", { name: /^Account/ }).hover();
      for (const route of ["claude-sr2", "Claude Code (work)"])
        await page.getByRole("menuitemradio", { name: route, exact: true }).waitFor();
    } finally {
      await page.close();
    }
  });
});
