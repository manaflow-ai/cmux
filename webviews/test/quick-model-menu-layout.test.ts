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
      expect(await page.locator(".acpmux-quick-rail-tab").count()).toBe(11);
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
      await page.locator(".acpmux-quick-model-effort .acpmux-quick-effort").first().waitFor({ state: "attached" });
      const menu = await bounds(page, ".acpmux-quick-menu");
      const rail = await bounds(page, ".acpmux-quick-rail");
      await page.getByRole("button", { name: "Codex", exact: true }).click();
      await page.waitForFunction(
        () =>
          document.querySelector(".acpmux-quick-rail-tab[aria-pressed=true]")?.getAttribute("aria-label") === "Codex",
      );
      await page.locator(".acpmux-quick-model-effort .acpmux-quick-effort").first().waitFor({ state: "attached" });
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
      expect(await page.getByRole("button", { name: "Claude Code (sr)", exact: true }).count()).toBe(1);
      await page.getByRole("menuitem", { name: /^Provider/ }).hover();
      await page.getByRole("menuitemradio", { name: "API key", exact: true }).waitFor();
    } finally {
      await page.close();
    }
  });

  test("the picker uses native menu rows and a left harness rail", async () => {
    const page = await open("claude");
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

  // Leo 2026-10-29, on #26521 giving every model a full row of levels: "BRO WHAT KIND OF FUCKING DESIGN
  // IS THIS????", then "i highly doubt you need the effort levels spelled out everywhere... sliders are
  // fine in many cases". One line per model and one slider at a time, on the model's own line.
  test("effort slider: one line per model, one slider, on the running row until another is hovered", async () => {
    for (const variant of ["codex", "codex-top"]) {
      const page = await open(variant, 680, 760, "agent-pane.inline-model-effort");
      try {
        await page.locator(".acpmux-quick-model-effort").first().waitFor();
        const shown = () =>
          page.$$eval(".acpmux-quick-model-effort", (rows) =>
            rows.map((row) => {
              const slider = row.querySelector(".acpmux-quick-effort")!;
              const name = row.querySelector(".acpmux-quick-item")!.getBoundingClientRect();
              const box = slider.getBoundingClientRect();
              return {
                name: row.querySelector(".acpmux-menu-label")?.textContent,
                height: Math.round(row.getBoundingClientRect().height),
                slider: getComputedStyle(slider).display !== "none",
                sameLine: box.height === 0 || Math.abs(box.top + box.height / 2 - (name.top + name.height / 2)) <= 0.5,
              };
            }),
          );
        const rest = await shown();
        expect(rest).toHaveLength(9);
        expect(rest.filter((row) => row.slider).map((row) => row.name)).toEqual(["GPT-6.1 Sol"]);
        for (const row of rest) {
          expect(row.height).toBeLessThanOrEqual(28);
          expect(row.sameLine).toBe(true);
        }
        // No level is spelled out as a row of words: one level name shows, beside its slider.
        expect(await page.locator(".acpmux-quick-effort-level:visible").allTextContents()).toEqual(["Extra High"]);
        const astra = page.locator(".acpmux-quick-model-effort", { hasText: "GPT-6 Astra" });
        await astra.locator(".acpmux-quick-item").first().hover();
        const hovered = await shown();
        expect(hovered.filter((row) => row.slider).map((row) => row.name)).toEqual(["GPT-6 Astra"]);
        for (const row of hovered) expect(row.height).toBeLessThanOrEqual(28);
        // A stop on the hovered row lands that model and level together, in one click.
        const high = (await astra.locator('.acpmux-effort-stop[data-level="high"]').boundingBox())!;
        await page.mouse.move(high.x + high.width / 2, high.y + high.height / 2);
        await page.mouse.down();
        await page.mouse.up();
        await page.waitForFunction(
          () => document.querySelector("[data-model]")?.getAttribute("data-model") === "gpt-6-astra",
        );
        expect(await page.locator("[data-model]").getAttribute("data-effort")).toBe("high");
      } finally {
        await page.close();
      }
    }
  });

  // Leo 2026-10-29, on the old slider: "it was just shit looking bc the circle center wasn't on the
  // selection scenter". At every level, ends included, the thumb's centre is its stop's centre, the
  // stops and the level's name share one centre line, and every edge lands on a whole pixel.
  test("effort slider: the thumb centres on its stop at every level, on whole pixels", async () => {
    for (const level of ["low", "medium", "high", "xhigh", "max", "ultra"]) {
      const page = await open(`level-${level}`, 680, 760, "agent-pane.inline-model-effort");
      try {
        const slider = page.locator(".acpmux-quick-model-effort[data-running] .acpmux-quick-effort");
        await slider.waitFor();
        const geometry = await slider.evaluate((node) => {
          const rect = (selector: string) => node.querySelector(selector)!.getBoundingClientRect();
          const thumb = rect(".acpmux-effort-thumb");
          const at = node.querySelector<HTMLElement>(".acpmux-effort-stop[data-at]")!;
          const stop = at.getBoundingClientRect();
          const track = rect(".acpmux-effort-track");
          const label = rect(".acpmux-quick-effort-level");
          const stops = [...node.querySelectorAll(".acpmux-effort-stop")].map((each) => each.getBoundingClientRect());
          return {
            level: at.dataset.level,
            thumbX: thumb.left + thumb.width / 2,
            thumbY: thumb.top + thumb.height / 2,
            stopX: stop.left + stop.width / 2,
            stopY: stop.top + stop.height / 2,
            labelY: label.top + label.height / 2,
            trackLeft: track.left,
            trackRight: track.right,
            thumbLeft: thumb.left,
            thumbRight: thumb.right,
            edges: [thumb.left, thumb.top, ...stops.flatMap((each) => [each.left, each.top])],
            stopYs: stops.map((each) => each.top + each.height / 2),
          };
        });
        expect(geometry.level).toBe(level);
        expect(Math.abs(geometry.thumbX - geometry.stopX)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(geometry.thumbY - geometry.stopY)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(geometry.labelY - geometry.stopY)).toBeLessThanOrEqual(0.5);
        for (const y of geometry.stopYs) expect(Math.abs(y - geometry.stopY)).toBeLessThanOrEqual(0.5);
        // The ends: the thumb sits flush inside the track, never past it.
        if (level === "low") expect(Math.abs(geometry.thumbLeft - geometry.trackLeft)).toBeLessThanOrEqual(0.5);
        if (level === "ultra") expect(Math.abs(geometry.thumbRight - geometry.trackRight)).toBeLessThanOrEqual(0.5);
        for (const edge of geometry.edges) expect(Math.abs(edge * 2 - Math.round(edge * 2))).toBeLessThan(0.01);
      } finally {
        await page.close();
      }
    }
  });

  test("inline effort keeps the compact rail at its narrow geometry", async () => {
    const page = await open("compact", 640, 560, "agent-pane.inline-model-effort");
    try {
      const rail = await bounds(page, ".acpmux-quick-rail");
      expect(rail.width).toBeGreaterThanOrEqual(76);
      expect(rail.width).toBeLessThan(110);
      expect(await page.locator(".acpmux-quick-effort .acpmux-effort-track").count()).toBeGreaterThan(0);
    } finally {
      await page.close();
    }
  });

  test("every harness placement leaves the model rows visible", async () => {
    for (const variant of ["harness-left", "harness-top", "harness-compact"]) {
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

  test("a long account name keeps the Provider control readable in a narrow pane", async () => {
    for (const width of [320, 420]) {
      const page = await open("claude", width);
      try {
        const label = page.getByRole("menuitem", { name: /^Provider/ }).locator(".acpmux-menu-label");
        expect(await label.evaluate((node) => node.scrollWidth <= node.clientWidth)).toBe(true);
        await page.getByRole("menuitem", { name: /^Provider/ }).hover();
        await page.getByRole("menuitemradio", { name: "API key", exact: true }).waitFor();
      } finally {
        await page.close();
      }
    }
  });

  test("searching from a launch entry selects the visible model, not that launch entry", async () => {
    const page = await open("claude");
    try {
      await page.keyboard.press("ArrowLeft");
      expect(await page.locator(".acpmux-quick-rail-add").evaluate((node) => node === document.activeElement)).toBe(
        true,
      );
      await page.keyboard.press("ArrowLeft");
      await page.waitForFunction(
        () => document.querySelector('.acpmux-quick-rail-tab[aria-pressed="true"]')?.textContent === "Claude Code (sr)",
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
});
