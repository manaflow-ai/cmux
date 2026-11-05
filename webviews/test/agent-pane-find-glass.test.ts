// l10n-allow-file: sample transcript labels, not shipped UI.
// Leo, 2026-11-05, on Cmd-F in the agent chat: "I don't think it's glass enough, and then second
// off, it ... takes off the blur of the top bar bit that is otherwise there to ... make it less
// sort of weird to see that ... difference between the top bar and then the text." Opening Find keeps
// the transcript's top fade (full ink only over the bar's own box), and the pill is the shared glass
// material: its blur and saturation, its lit rim over the popup's hairline and drop.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-find-glass.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  const extra: PapercutStep[] = [];
  for (let turn = 1; turn <= 30; turn++) {
    extra.push(
      ["mux", "user_message", { text: `Question ${turn}` }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId: "agent-1",
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: `Answer ${turn}: the checks on the merged head are green.` },
            },
          },
        },
      ],
      ["mux", "turn_result", { status: "completed" }],
    );
  }
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 0,
      running: false,
      extra,
      ready: ".acpmux-scroll .cv-user__bubble",
    });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  /// Stills for the PR (light and dark, text scrolled under the top band): set FIND_GLASS_MEDIA_DIR.
  const capture = async (page: Page, name: string) => {
    const directory = process.env.FIND_GLASS_MEDIA_DIR;
    if (!directory) return;
    await mkdir(directory, { recursive: true });
    await page.screenshot({ path: `${directory}/${name}.png`, clip: { x: 0, y: 0, width: 900, height: 260 } });
  };
  const openFind = async (page: Page) => {
    await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("find"));
    const field = page.locator(".acpmux-find .find-pill__field");
    // One match in the middle: Find keeps the view scrolled, with rows under the top band.
    await field.fill("Answer 16:");
    await page.waitForFunction(() => document.querySelector(".find-pill__count")?.textContent === "1 of 1");
  };
  const scrolledPage = async (colorScheme: "light" | "dark") => {
    const page = await pane.open({ width: 900, height: 700, scale: 2, colorScheme });
    // Away from the start, so rows pass under the top band and it fades.
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.scrollTop = Math.max(0, node.scrollHeight / 2 - 7);
    });
    await page.waitForSelector(".acpmux-scroll[data-fade-top]");
    return page;
  };

  for (const colorScheme of ["dark", "light"] as const) {
    test(`${colorScheme}: Find keeps the transcript's top fade and leaves full ink only over the bar`, async () => {
      const page = await scrolledPage(colorScheme);
      try {
        await capture(page, `closed-${colorScheme}`);
        await openFind(page);
        // The pill's open animation (findPill.css find-pill-in) ends before the still.
        await page.evaluate(() =>
          Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined))),
        );
        await capture(page, `open-${colorScheme}`);
        const read = await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const bar = document.querySelector<HTMLElement>(".acpmux-find__bar")!;
          const style = getComputedStyle(scroller);
          const box = bar.getBoundingClientRect();
          const view = scroller.getBoundingClientRect();
          return {
            fadeTop: style.getPropertyValue("--acpmux-fade-top").trim(),
            x: parseFloat(scroller.style.getPropertyValue("--acpmux-find-x")),
            width: parseFloat(scroller.style.getPropertyValue("--acpmux-find-width")),
            barX: box.left - view.left,
            barWidth: box.width,
            masks: (style.maskImage || style.webkitMaskImage).match(/linear-gradient/g)?.length ?? 0,
            sizes: style.maskSize || style.webkitMaskSize,
          };
        });
        // The fade stays: it used to drop to 0px while Find was open.
        expect(read.fadeTop).toBe("18px");
        // The full-ink layer sits over the bar's own box, feathered 16px past each side.
        expect(Math.abs(read.x - read.barX)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(read.width - read.barWidth)).toBeLessThanOrEqual(0.5);
        expect(read.width).toBeGreaterThan(100);
        expect(read.masks).toBeGreaterThanOrEqual(3);
        expect(read.sizes).toContain(`${read.width + 32}px`);

        await page.keyboard.press("Escape");
        await page.locator(".acpmux-find").waitFor({ state: "detached" });
        const cleared = await page
          .locator(".acpmux-scroll")
          .evaluate((node: HTMLElement) => node.style.getPropertyValue("--acpmux-find-width"));
        expect(cleared).toBe("");
      } finally {
        await page.close();
      }
    });
  }

  test("the find pill is the shared glass material", async () => {
    const page = await scrolledPage("dark");
    try {
      await openFind(page);
      const pill = await page.locator(".acpmux-find .find-pill").evaluate((node) => {
        const style = getComputedStyle(node);
        const color = style.backgroundColor;
        const alpha = /\/\s*([\d.]+)\s*\)$/.exec(color)?.[1] ?? /rgba\([^)]*,\s*([\d.]+)\)$/.exec(color)?.[1] ?? "1";
        return {
          backdrop: style.backdropFilter || style.webkitBackdropFilter,
          shadow: style.boxShadow,
          alpha: Number(alpha),
        };
      });
      expect(pill.backdrop).toContain("blur(24px)");
      expect(pill.backdrop).toContain("saturate(1.8)");
      // The material's lit rim (glass.css --glass-material-rim) over the popup's drop.
      expect(pill.shadow).toContain("1px 1.5px 1px -1px inset");
      expect(pill.shadow).toContain("0px 16px 20px -16px inset");
      expect(pill.alpha).toBeLessThan(1);
    } finally {
      await page.close();
    }
  });
});
