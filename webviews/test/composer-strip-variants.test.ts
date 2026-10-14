// l10n-allow-file: test fixture names and expected English labels, not shipped UI.
// The composer strip (hq#1957, Leo and Lawrence 2026-10-14): one strip on the composer card's top
// edge holds the folder and machine, then the chat's pull request, then its running subagents. Four
// variants (flat, tab, gooey, tray) behind the `composer-strip` experiment and the app's Debug
// Settings choice; `off` keeps the location strip and the pull request dock above it. For each
// variant:
//   - the strip holds the context chips, the pull request chip and the subagent chips in order;
//   - more than one pull request shows the newest and +N; more than two subagents one chip naming
//     how many; each opens a popover listing them;
//   - clicking a subagent asks the app for its pane (`chat.subagentPane`);
//   - a finished subagent stays a moment, then leaves;
//   - the strip never overlaps the queue or the card;
//   - appearance.borders = none clears the strip's rims;
//   - the hugging variants animate their width, and nothing animates under Reduce Motion.
//
// Real Chromium from Playwright on the gallery's stage (`agent-pane.composer-strip-variants`);
// CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { AGENTS, stripAgent, stripChat } from "../src/agent-session/acpmux/strip/composerStripVariants.gallery";

type Rect = { left: number; right: number; top: number; bottom: number; width: number; height: number };

await requireBrowserLane("composer-strip-variants.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-strip-variants: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer strip variants", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.composer-strip-variants";
  const stageURL = (variant: string, arm: string, extra = "") =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${ENTRY}&variant=${variant}&exp=composer-strip&arm=${arm}${extra}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 720, height: 420 } });
    await warm.goto(stageURL("one-agent", "tab"));
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

  const open = async (variant: string, arm: string, { width = 720, extra = "" } = {}): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 420 } });
    await page.goto(stageURL(variant, arm, extra));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    await page.locator(".acpmux-composer-box").waitFor();
    return page;
  };
  /** Delivers a snapshot through the pane's bridge, as the app's next snapshot arrives. */
  const deliver = (page: Page, snapshot: unknown) =>
    page.evaluate((next) => {
      (window as unknown as { cmuxAcpmuxBridge: { receive(value: unknown): void } }).cmuxAcpmuxBridge.receive(next);
    }, snapshot);

  /** Runs in the page: the strip's parts, left to right. */
  function stripParts() {
    const rect = (element: Element | null) => {
      if (!element) return null;
      const { left, right, top, bottom, width, height } = element.getBoundingClientRect();
      return { left, right, top, bottom, width, height };
    };
    const strip = document.querySelector(".acpmux-composer-strip");
    const row = strip?.querySelector(".acpmux-composer-context") ?? null;
    return {
      row: rect(row),
      leading: rect(strip?.querySelector(".acpmux-location-leading") ?? null),
      pr: rect(strip?.querySelector(".acpmux-strip-pr") ?? null),
      agents: [...(strip?.querySelectorAll(".acpmux-strip-agent, .acpmux-strip-agents-summary") ?? [])].map(rect),
      dock: document.querySelector(".acpmux-pr-dock") !== null,
    };
  }

  const STRIPS = ["flat", "tab", "gooey", "tray"] as const;

  for (const arm of STRIPS) {
    describe(arm, () => {
      test("the strip holds the folder and machine, then the pull request, then the running subagent", async () => {
        const page = await open("one-agent", arm);
        await page.locator(".acpmux-strip-agent").waitFor();
        const parts = await page.evaluate(stripParts);
        const form = await page.locator(".acpmux-composer").getAttribute("data-composer-strip");
        await page.close();
        expect(form).toBe(arm);
        expect(parts.dock).toBe(false);
        const { row, leading, pr } = parts as { row: Rect; leading: Rect; pr: Rect };
        expect(pr).not.toBeNull();
        expect(parts.agents.length).toBe(1);
        const agent = parts.agents[0]!;
        expect(leading.right).toBeLessThanOrEqual(pr.left + 0.5);
        expect(pr.right).toBeLessThanOrEqual(agent.left + 0.5);
        // One row: every chip sits inside the strip's row, which holds them all.
        for (const part of [leading, pr, agent]) {
          expect(part.top).toBeGreaterThanOrEqual(row.top - 0.5);
          expect(part.bottom).toBeLessThanOrEqual(row.bottom + 0.5);
          expect(part.right).toBeLessThanOrEqual(row.right + 0.5);
        }
      });

      test("more than one pull request shows the newest and +N, whose popover lists them all", async () => {
        const page = await open("three-prs", arm);
        await page.locator(".acpmux-strip-more").waitFor();
        expect(await page.locator(".acpmux-strip-pr").count()).toBe(1);
        expect(await page.locator(".acpmux-strip-pr .acpmux-strip-number").textContent()).toBe("#43");
        expect(await page.locator(".acpmux-strip-pr").getAttribute("href")).toBe(
          "https://github.com/acme/atlas-web/pull/43",
        );
        expect(await page.locator(".acpmux-strip-more").textContent()).toBe("+2");
        await page.locator(".acpmux-strip-more").click();
        const rows = page.locator(".acpmux-strip-menu a.acpmux-strip-menu-row");
        await rows.first().waitFor();
        expect(await rows.evaluateAll((all) => all.map((row) => row.getAttribute("href")?.split("/").pop()))).toEqual([
          "43",
          "42",
          "41",
        ]);
        // Dismiss lives in the popover, never on the chip.
        expect(await page.locator(".acpmux-strip-pr .acpmux-strip-dismiss").count()).toBe(0);
        await page.getByRole("button", { name: "Dismiss pull request #42" }).click();
        await page.waitForFunction(() => document.querySelector(".acpmux-strip-more")?.textContent === "+1");
        await page.close();
      });

      test("more than two running subagents collapse to one chip naming how many", async () => {
        const page = await open("three-agents", arm);
        await page.locator(".acpmux-strip-agents-summary").waitFor();
        expect(await page.locator(".acpmux-strip-agent").count()).toBe(0);
        expect(await page.locator(".acpmux-strip-agents-summary").textContent()).toContain("3 subagents");
        await page.locator(".acpmux-strip-agents-summary").click();
        const rows = page.locator(".acpmux-strip-menu .acpmux-strip-menu-row");
        await rows.first().waitFor();
        expect(await rows.count()).toBe(3);
        await page.close();
      });

      test("clicking a subagent asks the app for its pane", async () => {
        const page = await open("one-agent", arm);
        await page.locator(".acpmux-strip-agent").click();
        await page.waitForFunction(() =>
          (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.some(
            (entry) => entry.method === "chat.subagentPane",
          ),
        );
        const call = await page.evaluate(() =>
          (window as unknown as { cmuxGalleryLog: { method: string; params?: unknown }[] }).cmuxGalleryLog.find(
            (entry) => entry.method === "chat.subagentPane",
          ),
        );
        await page.close();
        expect(call?.params).toMatchObject({ subagent: AGENTS[0]!.id });
      });

      test("a finished subagent stays a moment, then leaves the strip", async () => {
        const page = await open("one-agent", arm);
        await page.locator(".acpmux-strip-agent").waitFor();
        const finished = stripChat(1, [stripAgent("Retry policy", 3, "completed")]);
        const started = Date.now();
        await deliver(page, finished);
        await page.locator('.acpmux-strip-agent[data-status="done"]').waitFor({ timeout: 1000 });
        await page.waitForFunction(() => document.querySelector(".acpmux-strip-agent") === null, undefined, {
          timeout: 5000,
        });
        const gone = Date.now() - started;
        await page.close();
        expect(gone).toBeGreaterThanOrEqual(1500);
      });

      test("the strip never overlaps the queue or the card", async () => {
        const page = await open("queued", arm);
        await page.locator(".acpmux-composer-queue").waitFor();
        const measured = await page.evaluate(() => {
          const rect = (selector: string) => {
            const { top, bottom, left, right } = document.querySelector(selector)!.getBoundingClientRect();
            return { top, bottom, left, right };
          };
          return {
            queue: rect(".acpmux-composer-queue"),
            strip: rect(".acpmux-composer-strip"),
            row: rect(".acpmux-composer-strip > .acpmux-composer-context"),
            card: rect(".acpmux-composer-box"),
            transcript: rect(".acpmux-main .acpmux-scroll"),
          };
        });
        await page.close();
        expect(measured.queue.bottom).toBeLessThanOrEqual(measured.strip.top + 0.5);
        // The tray runs under the card by design; its row, which holds the chips, never does.
        expect((arm === "tray" ? measured.row : measured.strip).bottom).toBeLessThanOrEqual(measured.card.top + 0.5);
        expect(measured.queue.top).toBeGreaterThanOrEqual(measured.transcript.bottom - 0.5);
        expect(measured.strip.left).toBeGreaterThanOrEqual(measured.card.left - 0.5);
        expect(measured.strip.right).toBeLessThanOrEqual(measured.card.right + 0.5);
      });

      test("appearance.borders = none clears the strip's rims", async () => {
        const page = await open("one-agent", arm);
        const rims = await page.evaluate(() => {
          document.documentElement.dataset.borders = "none";
          const strip = document.querySelector(".acpmux-composer-strip")!;
          // Every color a rim can draw in: the strip's shadow, its fillets' ring, the card's ring.
          const colors = (value: string) => value.match(/rgba?\([^)]*\)|transparent/g) ?? [];
          const opaque = (color: string) => color !== "transparent" && !/,\s*0\)$/.test(color);
          const edge = getComputedStyle(strip).getPropertyValue("--acpmux-strip-edge").trim();
          return {
            edge,
            stripShadow: colors(getComputedStyle(strip).boxShadow).filter(opaque),
            card: colors(
              getComputedStyle(document.querySelector(".acpmux-composer-box")!, "::before").boxShadow,
            ).filter(opaque),
          };
        });
        await page.close();
        expect(rims.edge).toBe("transparent");
        expect(rims.stripShadow).toEqual([]);
        expect(rims.card).toEqual([]);
      });
    });
  }

  for (const arm of ["tab", "gooey"] as const)
    test(`${arm}: the strip's width animates as items come and go, and is instant under Reduce Motion`, async () => {
      const grow = async (extra: string) => {
        const page = await open("context", arm, { extra, width: 1100 });
        const before = await page.evaluate(
          () => document.querySelector(".acpmux-composer-strip")!.getBoundingClientRect().width,
        );
        await deliver(page, stripChat(1, AGENTS.slice(0, 1)));
        await page.locator(".acpmux-strip-agent").waitFor();
        // The next frame, as painted: the strip's ResizeObserver has run.
        const measured = await page.evaluate(async () => {
          await new Promise(requestAnimationFrame);
          const form = document.querySelector(".acpmux-composer")!;
          const strip = document.querySelector(".acpmux-composer-strip")!;
          const row = strip.querySelector(".acpmux-composer-context")!;
          return {
            transition: form
              .getAnimations()
              .some((animation) => (animation as CSSTransition).transitionProperty === "--acpmux-strip-width"),
            width: strip.getBoundingClientRect().width,
            row: row.getBoundingClientRect().width,
          };
        });
        await page.waitForFunction(
          () =>
            Math.abs(
              document.querySelector(".acpmux-composer-strip")!.getBoundingClientRect().width -
                document.querySelector(".acpmux-composer-strip .acpmux-composer-context")!.getBoundingClientRect()
                  .width,
            ) < 0.5,
        );
        const after = await page.evaluate(
          () => document.querySelector(".acpmux-composer-strip")!.getBoundingClientRect().width,
        );
        await page.close();
        return { before, after, ...measured };
      };
      const moving = await grow("");
      expect(moving.after).toBeGreaterThan(moving.before + 20);
      expect(moving.transition).toBe(true);
      const still = await grow("&reducedMotion=1");
      expect(still.transition).toBe(false);
      expect(Math.abs(still.width - still.row)).toBeLessThan(0.5);
    });

  test("the strip's chips move in only with motion allowed", async () => {
    const chipAnimations = async (extra: string) => {
      const page = await open("one-pr", "tray", { extra });
      await deliver(page, stripChat(1, AGENTS.slice(0, 1)));
      await page.locator(".acpmux-strip-agent").waitFor();
      const count = await page.evaluate(() => document.querySelector(".acpmux-strip-agent")!.getAnimations().length);
      await page.close();
      return count;
    };
    expect(await chipAnimations("")).toBeGreaterThan(0);
    expect(await chipAnimations("&reducedMotion=1")).toBe(0);
  });

  test("off keeps today's strip: folder and machine, the pull request dock above", async () => {
    const page = await open("one-agent", "off");
    await page.locator(".acpmux-pr-dock").waitFor();
    const measured = await page.evaluate(() => ({
      variant: document.querySelector(".acpmux-composer")!.getAttribute("data-composer-strip"),
      items: document.querySelectorAll(".acpmux-strip-items, .acpmux-strip-chip").length,
      leading: document.querySelector(".acpmux-composer-strip .acpmux-location-leading") !== null,
      dockAbove:
        document.querySelector(".acpmux-pr-dock")!.getBoundingClientRect().bottom <=
        document.querySelector(".acpmux-composer-strip")!.getBoundingClientRect().top + 0.5,
    }));
    await page.close();
    expect(measured).toEqual({ variant: null, items: 0, leading: true, dockAbove: true });
  });

  test("the app's choice (the theme's composerStrip) wins over the experiment arm", async () => {
    const page = await open("one-agent", "off");
    await page.locator(".acpmux-pr-dock").waitFor();
    await page.evaluate(() => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyTheme(theme: unknown): void } }).cmuxAcpmuxBridge;
      bridge.applyTheme({ isDark: true, composerStrip: "tab" });
    });
    await page.waitForFunction(
      () => document.querySelector(".acpmux-composer")?.getAttribute("data-composer-strip") === "tab",
    );
    expect(await page.locator(".acpmux-pr-dock").count()).toBe(0);
    expect(await page.locator(".acpmux-composer-strip .acpmux-strip-pr").count()).toBe(1);
    await page.evaluate(() => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyTheme(theme: unknown): void } }).cmuxAcpmuxBridge;
      bridge.applyTheme({ isDark: true });
    });
    await page.locator(".acpmux-pr-dock").waitFor();
    await page.close();
  });

  test("a narrow strip collapses the subagents first, then the pull request's title", async () => {
    const page = await open("one-agent", "flat", { width: 420 });
    await deliver(page, stripChat(3, AGENTS.slice(0, 2)));
    await page.locator(".acpmux-strip-agents-summary").waitFor();
    const narrow = await page.evaluate(() => {
      const strip = document.querySelector(".acpmux-composer-strip")!.getBoundingClientRect();
      return {
        agents: document.querySelectorAll(".acpmux-strip-agent").length,
        title: document.querySelectorAll(".acpmux-strip-pr-title").length,
        items: document.querySelector(".acpmux-strip-items")!.getBoundingClientRect().right <= strip.right + 0.5,
        leading: document.querySelector(".acpmux-location-leading")!.getBoundingClientRect().width,
      };
    });
    await page.close();
    expect(narrow.agents).toBe(0);
    expect(narrow.title).toBe(0);
    expect(narrow.items).toBe(true);
    // The folder and machine keep a readable width.
    expect(narrow.leading).toBeGreaterThanOrEqual(100);
  });
});
