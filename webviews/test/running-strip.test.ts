// The tray line of a running command above the composer is quiet at rest and one box (Leo
// 2026-10-21, on a strip whose line was a filled pill inside the tray's bordered glass, with uneven
// insets: ""padding" this one tho i think is mostly a matter of like... well why is that even
// highlighted in the first place? you can click on it to go somewhere? is that a command or a
// subagent?").
// - At rest nothing inside the tray has a fill of its own. (The pill in the screenshot was the
//   line's hover: summary.css's opaque --acpmux-menu-hover at a 7px radius, inside the tray's 2px
//   padding.)
// - Hovering a line that opens something fills the whole line, its stop button included, out to
//   the tray's own edges (one inset, never a pill inside the strip), with the arrow cursor; the
//   line's button draws no second fill.
// - A line with nothing to open has no hover at all.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { openRunningTray } from "./support/openRunningTray";

await requireBrowserLane("running-strip.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("running-strip: skipping (run `bunx playwright install chromium`)");
    describe.skip("running strip", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/running-strip.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(clickable: boolean): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 760, height: 200 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate(
      (value) => (window as unknown as { __showTray: (c: boolean) => void }).__showTray(value),
      clickable,
    );
    // One line heads the hat folded (Leo, 2026-11-07): its header opens it; the pointer then leaves
    // the header, so what the tests read is the line at rest.
    await page.waitForSelector(".acpmux-running-tray");
    await openRunningTray(page);
    await page.mouse.move(0, 0);
    await page.waitForSelector(".acpmux-running-tray .acpmux-agent-line");
    // The header's hover wash fades out (summary.css's background transition): wait for the pointer
    // to have left it and finish that fade, so the line is read at rest.
    await page.waitForFunction(() => !document.querySelector(".acpmux-running-tray__head:hover"));
    await page.evaluate(() => {
      for (const animation of document.getAnimations())
        if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
    });
    // The tray rises in as it joins the stack (bottomStack.css ui-enter): measure where it lands.
    return page;
  }

  /** The tray's descendants that paint a background of their own, by class. */
  const filled = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-running-tray *")]
        .filter((element) => {
          const color = getComputedStyle(element).backgroundColor;
          return color !== "rgba(0, 0, 0, 0)" && color !== "transparent";
        })
        .map((element) => element.className.toString() || element.tagName),
    );

  test("at rest nothing inside the tray has a fill", async () => {
    const page = await open(true);
    try {
      expect(await filled(page)).toEqual([]);
    } finally {
      await page.close();
    }
  });

  test("hover fills the whole line to the tray's edges, its stop button inside, with the arrow", async () => {
    const page = await open(true);
    try {
      await page.hover(".acpmux-agent-line__button");
      // One fill, on the line: its button draws none of its own (no box in a box).
      expect(await filled(page)).toEqual(["acpmux-agent-line"]);
      const geometry = await page.evaluate(() => {
        const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
        const line = document.querySelector<HTMLElement>(".acpmux-agent-line")!;
        const stop = line.querySelector<HTMLElement>(".acpmux-session-info-stop")!;
        const box = tray.getBoundingClientRect();
        const inner = {
          left: box.left + tray.clientLeft,
          right: box.left + tray.clientLeft + tray.clientWidth,
        };
        const rect = line.getBoundingClientRect();
        const stopRect = stop.getBoundingClientRect();
        return {
          left: rect.left - inner.left,
          right: inner.right - rect.right,
          stopInside: stopRect.left >= rect.left && stopRect.right <= rect.right,
          cursor: getComputedStyle(line.querySelector(".acpmux-agent-line__button")!).cursor,
        };
      });
      expect(geometry.left).toBeCloseTo(0, 1);
      expect(geometry.right).toBeCloseTo(0, 1);
      expect(geometry.stopInside).toBe(true);
      expect(geometry.cursor).toBe("default");
      // On the stop button the line keeps its one fill; the button only brightens.
      await page.hover(".acpmux-session-info-stop");
      expect(await filled(page)).toEqual(["acpmux-agent-line"]);
    } finally {
      await page.close();
    }
  });

  // Leo 2026-10-25: the collapse at the top "disappears for some reason at the top ... sometimes".
  // 120px squeezes the list to under three lines; 72px leaves the list little or no room. Every line
  // is in the list, with no View all under it (Leo, 2026-11-01: "just let it be scroll-downable").
  for (const height of [400, 120, 72]) {
    test(`with 118 agents the header stays in view while the list scrolls (dock ${height}px)`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 600 } });
      try {
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
        await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
        await page.evaluate(
          (value) => (window as unknown as { __showPanel: (h: number) => void }).__showPanel(value),
          height,
        );
        await page.waitForSelector(".acpmux-running-tray__head");
        await openRunningTray(page);
        expect(await page.$(".acpmux-running-tray__finished")).toBeNull();
        await page.waitForFunction(
          () => document.querySelectorAll(".acpmux-running-tray li[data-finished]").length === 116,
        );
        // Scroll everything that can scroll to its end, the tray itself included, as a wheel would.
        const listHeight = await page.$eval(".acpmux-running-tray__list", (list) => list.clientHeight);
        await page.hover(listHeight > 0 ? ".acpmux-running-tray__list" : ".acpmux-running-tray__head");
        for (let step = 0; step < 20; step += 1) await page.mouse.wheel(0, 800);
        const state = await page.evaluate((h) => {
          const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
          const list = tray.querySelector<HTMLElement>(".acpmux-running-tray__list")!;
          const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
          tray.scrollTop = 10_000;
          const box = tray.getBoundingClientRect();
          const rect = head.getBoundingClientRect();
          const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
          return {
            // The list really scrolls wherever it has room; at the tightest squeeze it may have none.
            listScrolled:
              list.scrollHeight > list.clientHeight && (list.clientHeight === 0 ? h === 72 : list.scrollTop > 0),
            trayScroll: tray.scrollTop,
            headTop: rect.top - box.top,
            headHeight: rect.height,
            headDrawn: !!hit && head.contains(hit),
          };
        }, height);
        expect(state.listScrolled).toBe(true);
        expect(state.trayScroll).toBe(0);
        expect(state.headTop).toBeCloseTo(0, 0);
        expect(state.headHeight).toBeGreaterThan(20);
        expect(state.headDrawn).toBe(true);
      } finally {
        await page.close();
      }
    });
  }

  test("in a narrow tray an open command's actions wrap inside it, never clipped", async () => {
    // Review of #37830 (F1): its one foot line could not wrap, so a narrow tray cut off Open in terminal.
    const page = await browser!.newPage({ viewport: { width: 760, height: 400 } });
    try {
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
      await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
      await page.evaluate(() =>
        (window as unknown as { __showOpenCommand: (width: number, line: string) => void }).__showOpenCommand(
          260,
          "gh pr checks 34769 --repo manaflow-ai/cmux --watch",
        ),
      );
      await page.waitForSelector(".acpmux-running-tray");
      await openRunningTray(page);
      await page.click(".acpmux-running-tray .acpmux-agent-line__button");
      await page.waitForSelector(".acpmux-running-tray__tail button");
      await page.waitForSelector(".acpmux-running-tray__tail a");
      const fit = await page.evaluate(() => {
        const tail = document.querySelector<HTMLElement>(".acpmux-running-tray__tail")!.getBoundingClientRect();
        return [...document.querySelectorAll<HTMLElement>(".acpmux-running-tray__tail :is(a, button)")].map(
          (control) => {
            const box = control.getBoundingClientRect();
            return { left: box.left - tail.left, right: tail.right - box.right };
          },
        );
      });
      expect(fit.length).toBe(2);
      for (const control of fit) {
        expect(control.left).toBeGreaterThanOrEqual(-0.5);
        expect(control.right).toBeGreaterThanOrEqual(-0.5);
      }
    } finally {
      await page.close();
    }
  });

  test("an open command's time, state and Open in terminal share one line on the command's left edge", async () => {
    // Leo, 2026-11-07, on the open command's last line ("33s", "No output yet", "Open in terminal" each at
    // their own height): "also for the hat wow this is wildly misaligned at the bottom".
    const page = await browser!.newPage({ viewport: { width: 760, height: 400 } });
    try {
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
      await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
      await page.evaluate(() => (window as unknown as { __showOpenCommand: () => void }).__showOpenCommand());
      await page.waitForSelector(".acpmux-running-tray");
      await openRunningTray(page);
      await page.click(".acpmux-running-tray .acpmux-agent-line__button");
      await page.waitForSelector(".acpmux-running-tray__tail button");
      await page.mouse.move(0, 0);
      const line = await page.evaluate(() => {
        const tail = document.querySelector<HTMLElement>(".acpmux-running-tray__tail")!;
        const textBox = (element: Element) => {
          const range = document.createRange();
          range.selectNodeContents(element);
          const rects = [...range.getClientRects()].filter((rect) => rect.width > 0);
          const top = Math.min(...rects.map((rect) => rect.top));
          const bottom = Math.max(...rects.map((rect) => rect.bottom));
          return { left: rects[0]!.left, middle: (top + bottom) / 2 };
        };
        const leaf = (text: string) =>
          [...tail.querySelectorAll<HTMLElement>("*")].find(
            (element) => element.childElementCount === 0 && element.textContent?.trim() === text,
          ) ?? [...tail.querySelectorAll<HTMLElement>("*")].find((element) => element.textContent?.trim() === text)!;
        const command = tail.querySelector(".acpmux-bg-card__command")!;
        const time = tail.querySelector(".acpmux-running-tray__meta")!;
        const state = leaf("No output yet");
        const button = tail.querySelector("button")!;
        const label = [...button.childNodes].find((node) => node.nodeType === Node.TEXT_NODE)!;
        const labelRange = document.createRange();
        labelRange.selectNodeContents(label);
        const labelRect = labelRange.getBoundingClientRect();
        const icon = button.querySelector("svg")!.getBoundingClientRect();
        const size = (element: Element) => getComputedStyle(element).fontSize;
        return {
          commandLeft: textBox(command).left,
          timeLeft: textBox(time).left,
          middles: [
            textBox(time).middle,
            textBox(state).middle,
            labelRect.top + labelRect.height / 2,
            icon.top + icon.height / 2,
          ],
          sizes: [size(time), size(state), size(button)],
        };
      });
      expect(Math.abs(line.timeLeft - line.commandLeft)).toBeLessThan(1);
      const [first, ...rest] = line.middles;
      for (const middle of rest) expect(Math.abs(middle - first!)).toBeLessThan(1);
      expect(new Set(line.sizes).size).toBe(1);
    } finally {
      await page.close();
    }
  });

  // Leo, 2026-11-07, on the hat's rows: "instead of the done on the left, you can just put like a check
  // mark right where this stop square would be", the title "glaeda-gh wait file ~..." cut well short of its
  // time, and "me clicking this, the entire box, it just feels like, okay, I would be expanding this. I
  // don't expect myself to be going to the exact place".
  async function rows(width = 720): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: width + 40, height: 600 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate((w) => (window as unknown as { __showRows: (w: number) => void }).__showRows(w), width);
    await page.waitForSelector(".acpmux-running-tray");
    await openRunningTray(page);
    await page.mouse.move(0, 0);
    return page;
  }
  const settle = (page: Page) =>
    page.evaluate(() => {
      for (const animation of document.getAnimations())
        if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
    });
  const lineOf = (page: Page, name: string) =>
    page.locator(".acpmux-running-tray .acpmux-agent-line__button", {
      has: page.locator(".acpmux-summary-agent__name", { hasText: name }),
    });

  test("a finished line's check sits in the Stop square's slot, after its time, never a Done on the left", async () => {
    const page = await rows();
    try {
      const marks = await page.evaluate(() => {
        const lines = [...document.querySelectorAll<HTMLElement>(".acpmux-running-tray .acpmux-agent-line")];
        const done = lines.find((line) => line.dataset.status === "done")!;
        const running = lines.find(
          (line) => line.dataset.status === "running" && line.querySelector(".cv-subagent__stop"),
        )!;
        const check = done.querySelector<HTMLElement>("[data-done-check]");
        const stop = running.querySelector<HTMLElement>(".cv-subagent__stop")!.getBoundingClientRect();
        const time = done.querySelector<HTMLElement>(".acpmux-agent-line__time")!.getBoundingClientRect();
        const box = check?.getBoundingClientRect();
        const visibleWords = [...done.querySelectorAll<HTMLElement>(".acpmux-agent-line__meta *")]
          .filter((node) => node.childElementCount === 0 && !node.closest(".acpmux-agent-line__sr"))
          .map((node) => node.textContent?.trim())
          .filter(Boolean);
        return {
          icon: Boolean(check?.querySelector('svg[data-icon="status.check"]')),
          centreDelta: box ? Math.abs(box.left + box.width / 2 - (stop.left + stop.width / 2)) : Number.NaN,
          afterTime: box ? box.left >= time.right : false,
          visibleWords,
        };
      });
      expect(marks.icon).toBe(true);
      expect(marks.centreDelta).toBeLessThan(1);
      expect(marks.afterTime).toBe(true);
      expect(marks.visibleWords).toEqual([]);
    } finally {
      await page.close();
    }
  });

  test("a line's title runs up to its time, cut only where it truly overflows", async () => {
    const page = await rows();
    try {
      const fit = await page.evaluate(() => {
        const line = (name: string) =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-running-tray .acpmux-agent-line")].find(
            (each) => each.querySelector(".acpmux-summary-agent__name")?.textContent === name,
          )!;
        const measure = (each: HTMLElement) => {
          const text = each.querySelector<HTMLElement>(".acpmux-summary-text")!;
          const time = each.querySelector<HTMLElement>(".acpmux-agent-line__time")!;
          return {
            gap: time.getBoundingClientRect().left - text.getBoundingClientRect().right,
            cut: text.scrollWidth > text.clientWidth,
          };
        };
        const command = [...document.querySelectorAll<HTMLElement>(".acpmux-running-tray .acpmux-agent-line")].find(
          (each) => each.querySelector(".acpmux-agent-line__latest-inline.is-code, .acpmux-agent-line__latest.is-code"),
        )!;
        return {
          long: measure(
            line(
              "Audit every background task row in the composer hat for clipped titles and misaligned trailing columns",
            ),
          ),
          command: measure(command),
          latest: command.querySelector(".is-code")!.textContent,
        };
      });
      // The title's box ends one column gap before the time, not a status column away.
      expect(fit.long.cut).toBe(true);
      expect(fit.long.gap).toBeLessThan(12);
      expect(fit.command.gap).toBeLessThan(12);
      // The shell line is whole in the DOM; the row's CSS ellipsis cuts it, never a character cap.
      expect(fit.latest).toBe(
        "glaeda-gh wait file ~/Projects/checkouts/cmux/composer-hat-row-check/.done --timeout 3600",
      );
    } finally {
      await page.close();
    }
  });

  for (const name of [
    "Audit every background task row in the composer hat for clipped titles and misaligned trailing columns",
    "Run the tray tests",
  ]) {
    test(`a click on a line expands it in place, never navigating (${name.slice(0, 16)})`, async () => {
      const page = await rows();
      try {
        const opened = () => page.evaluate(() => [...(window as unknown as { __opened: string[] }).__opened]);
        await lineOf(page, name).click();
        await settle(page);
        expect(await opened()).toEqual([]);
        expect(await lineOf(page, name).getAttribute("aria-expanded")).toBe("true");
        const detail = page.locator(".acpmux-running-tray [data-line-detail]");
        await detail.waitFor();
        await page.waitForFunction(() => {
          const node = document.querySelector<HTMLElement>(".acpmux-running-tray [data-line-detail]");
          return !!node && node.getBoundingClientRect().height > 10 && node.style.overflow === "";
        });
        expect(await detail.textContent()).toContain(name);
        // The way to the subagent is an explicit button in the detail.
        await page.click(".acpmux-running-tray [data-line-detail] button");
        expect(await opened()).toEqual([`agent:${name === "Run the tray tests" ? "done" : "long"}`]);
        // A second click folds it, on the same fold.
        await lineOf(page, name).click();
        await settle(page);
        await page.waitForFunction(() => !document.querySelector(".acpmux-running-tray [data-line-detail]"));
        expect(await lineOf(page, name).getAttribute("aria-expanded")).toBe("false");
      } finally {
        await page.close();
      }
    });
  }

  test("a command's line expands to its tail in place; its terminal is the tail's button", async () => {
    const page = await rows();
    try {
      const opened = () => page.evaluate(() => [...(window as unknown as { __opened: string[] }).__opened]);
      const command = ".acpmux-running-tray .acpmux-agent-line:has(.is-code) .acpmux-agent-line__button";
      await page.click(command);
      await settle(page);
      expect(await opened()).toEqual([]);
      await page.waitForSelector(".acpmux-running-tray [data-line-detail] .acpmux-running-tray__tail button");
      await page.click(".acpmux-running-tray [data-line-detail] .acpmux-running-tray__tail button");
      expect(await opened()).toEqual(["command:w/1"]);
    } finally {
      await page.close();
    }
  });

  for (const terminal of [true, false])
    test(`a click on a subagent's command title expands it; Open chat is the way to the subagent (terminal ${terminal})`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 600 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
      await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
      await page.evaluate(
        (value) => (window as unknown as { __showOwnedCommand: (t: boolean) => void }).__showOwnedCommand(value),
        terminal,
      );
      await page.waitForSelector(".acpmux-running-tray");
      await openRunningTray(page);
      await page.mouse.move(0, 0);
      try {
        const opened = () => page.evaluate(() => [...(window as unknown as { __opened: string[] }).__opened]);
        const line = page.locator(".acpmux-running-tray .acpmux-agent-line__button", {
          has: page.locator(".is-code"),
        });
        // The title, which names the subagent, is part of the line's toggle: no link of its own.
        await line.locator(".acpmux-summary-agent__name").click();
        await settle(page);
        expect(await opened()).toEqual([]);
        expect(await line.getAttribute("aria-expanded")).toBe("true");
        const foot = page.locator(".acpmux-running-tray [data-line-detail] .acpmux-running-tray__tail-foot");
        await foot.waitFor();
        const labels = await foot.locator("button").evaluateAll((buttons) => buttons.map((b) => b.textContent));
        expect(labels.some((text) => text?.includes("Open chat"))).toBe(true);
        expect(labels.some((text) => text?.includes("Open in terminal"))).toBe(terminal);
        await foot.locator("button", { hasText: "Open chat" }).click();
        expect(await opened()).toEqual(["agent:owner"]);
      } finally {
        await page.close();
      }
    });

  test("a line with nothing to open has no hover and no hand", async () => {
    const page = await open(false);
    try {
      await page.hover(".acpmux-agent-line__button", { force: true });
      expect(await filled(page)).toEqual([]);
      expect(await page.$eval(".acpmux-agent-line__button", (button) => getComputedStyle(button).cursor)).not.toBe(
        "pointer",
      );
    } finally {
      await page.close();
    }
  });
});
