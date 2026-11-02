// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// Tool disclosures at the end keep the bottom pinned with one compositor transform (Leo,
// 2026-10-31). Away from the end, the clicked row holds its pixel through its height fold.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-fold-anchor-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fold-anchor-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript fold anchor", () => test("chromium", () => {}));
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
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const output = (lines: number) =>
    Array.from({ length: lines }, (_, index) => `line ${index + 1}: the keeper trimmed the wick`).join("\n");
  const read = (id: string, lines = 30) => ({
    kind: "tool",
    text: "",
    tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: output(lines) },
  });
  const paragraphs = (count: number) =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down.",
    ).join("\n\n");
  /// A finished turn that worked first: its "Worked for" line opens to the calls.
  const turn = (index: number): Row[] => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-run`, "activity", undefined, { items: [read(`t${index}-a`), read(`t${index}-b`)] }),
    row(`t${index}-answer`, "assistant", paragraphs(2)),
    row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 9_000, toolCount: 2 }),
  ];
  const done = Array.from({ length: 8 }, (_, index) => turn(index)).flat();
  /// The turn still running: a call with output, then the reply streaming under it.
  const live = (version: number): Row[] => [
    row("live-user", "user", "Read the lantern log and summarize it."),
    row("live-run", "activity", undefined, { items: [read("live-log", 40)] }),
    row("live-answer", "assistant", paragraphs(version), { version, streaming: true }),
  ];

  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  /// Resolves once the view is at rest: no glide or fold running, and three painted frames in a row
  /// show the transcript scrolled and sized as the frame before.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const moving = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  const atLatest = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
  const scrollHeight = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollHeight);
  /// Marks the line `selector` finds last in the transcript, and returns where it is drawn.
  const probe = (page: Page, selector: string) =>
    page.evaluate((query) => {
      const lines = [...document.querySelectorAll<HTMLElement>(query)];
      const line = lines.at(-1)!;
      line.dataset.probe = "true";
      const box = line.getBoundingClientRect();
      return { top: box.top, x: box.left + 24, y: box.top + box.height / 2 };
    }, selector);
  /// Clicks the marked line, then follows it every painted frame for `ms`: how far it ever moved,
  /// whether a fold was playing, and whether the end stayed pinned to the composer.
  const clickAndWatch = async (page: Page, ms = 450, at?: { x: number; y: number }) => {
    const point = await page.evaluate(() => {
      const box = document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect();
      return { x: box.left + 24, y: box.top + box.height / 2, top: box.top };
    });
    const watching = page.evaluate(
      ({ duration, from }) =>
        new Promise<{
          moved: number;
          folded: boolean;
          stacked: number;
          bottomDrift: number;
          threadAnimations: number;
          threadDuration: number | null;
          animatedHeights: number;
        }>((resolve) => {
          const start = performance.now();
          let moved = 0;
          let folded = false;
          let stacked = 0;
          let bottomDrift = 0;
          const threadAnimations = new Set<Animation>();
          const animatedHeights = new Set<number>();
          let threadDuration: number | null = null;
          window.cmuxAfterPaint(() => {
            const line = document.querySelector<HTMLElement>("[data-probe]");
            if (line) moved = Math.max(moved, Math.abs(line.getBoundingClientRect().top - from));
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (scroller)
              bottomDrift = Math.max(
                bottomDrift,
                Math.abs(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
              );
            const thread = document.querySelector<HTMLElement>(".acpmux-thread");
            for (const animation of thread?.getAnimations() ?? []) {
              if (animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity) continue;
              threadAnimations.add(animation);
              if (scroller) animatedHeights.add(scroller.scrollHeight);
              const duration = animation.effect?.getTiming().duration;
              threadDuration = typeof duration === "number" ? duration : null;
            }
            for (const fold of document.querySelectorAll(".cv-fold"))
              if (fold.getAnimations().length > 0) folded = true;
            const each = new Map<unknown, number>();
            for (const animation of document.getAnimations())
              if (animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity) {
                const target = (animation.effect as KeyframeEffect | null)?.target;
                each.set(target, (each.get(target) ?? 0) + 1);
              }
            stacked = Math.max(stacked, ...each.values(), 0);
            if (performance.now() - start < duration) return;
            resolve({
              moved,
              folded,
              stacked,
              bottomDrift,
              threadAnimations: threadAnimations.size,
              threadDuration,
              animatedHeights: animatedHeights.size,
            });
            return false;
          });
        }),
      { duration: ms, from: point.top },
    );
    await page.mouse.click((at ?? point).x, (at ?? point).y);
    return { ...(await watching), top: point.top };
  };
  const probedTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect().top);
  const open = async (reducedMotion: "reduce" | "no-preference") => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };

  test("a tool call opened at the end pins the bottom and moves the transcript as one stack", async () => {
    const page = await open("no-preference");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    const aboveBefore = await page.locator('[data-row-id="live-user"]').evaluate((node) => {
      (node as HTMLElement).dataset.aboveProbe = "true";
      return (node as HTMLElement).getBoundingClientRect().top;
    });
    const earlierBefore = await page.locator('[data-row-id="t7-answer"]').evaluate((node) => {
      (node as HTMLElement).dataset.earlierProbe = "true";
      return (node as HTMLElement).getBoundingClientRect().top;
    });
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);

    const opened = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.folded).toBe(false);
    expect(opened.animatedHeights).toBe(1);
    expect(opened.bottomDrift).toBeLessThanOrEqual(2);
    expect(opened.threadAnimations).toBe(1);
    expect(opened.threadDuration).toBeGreaterThanOrEqual(150);
    expect(opened.threadDuration).toBeLessThanOrEqual(200);
    expect(opened.moved).toBeGreaterThan(1);
    await settle(page);
    const aboveAfter = await page
      .locator("[data-above-probe]")
      .evaluate((node) => (node as HTMLElement).getBoundingClientRect().top);
    const earlierAfter = await page
      .locator("[data-earlier-probe]")
      .evaluate((node) => (node as HTMLElement).getBoundingClientRect().top);
    expect(aboveAfter).toBeLessThan(aboveBefore - 1);
    expect(earlierAfter).toBeLessThan(earlierBefore - 1);
    expect(await atLatest(page)).toBe(true);

    const expandedEnd = await scrollHeight(page);
    // Closing keeps the expanded end and the clicked line, with no downward stack motion.
    const closed = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("false");
    expect(closed.bottomDrift).toBeLessThanOrEqual(2);
    expect(closed.moved).toBeLessThanOrEqual(1);
    expect(closed.threadAnimations).toBe(0);
    expect(await scrollHeight(page)).toBe(expandedEnd);
    expect(await atLatest(page)).toBe(true);

    // The room created by the expanded body remains after collapse. Scrolling up and back to the
    // latest row must not trim it or reintroduce a jump.
    const retainedEnd = await scrollHeight(page);
    await page.mouse.wheel(0, -260);
    await settle(page);
    expect(await atLatest(page)).toBe(false);
    expect(await scrollHeight(page)).toBe(retainedEnd);
    await page.mouse.wheel(0, 10_000);
    await settle(page);
    expect(await scrollHeight(page)).toBe(retainedEnd);
    expect(await atLatest(page)).toBe(true);

    // Reopening fills the retained room without moving the stack or adding a second gap.
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);
    const reopened = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(reopened.bottomDrift).toBeLessThanOrEqual(2);
    expect(reopened.threadAnimations).toBeLessThanOrEqual(1);
    expect(reopened.moved).toBeLessThanOrEqual(1);
    expect(await scrollHeight(page)).toBe(expandedEnd);
    expect(await atLatest(page)).toBe(true);
    await page.close();
  });

  test("away from the bottom a tool call expands downward without moving the earlier stack", async () => {
    const page = await open("no-preference");
    await show(page, [...done, ...live(8)]);
    await settle(page);
    // Keep enough content after the tool to place its actual hit target well inside the view
    // while remaining away from the end. A blind wheel can leave it under the bottom mask.
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const toggle = document.querySelector<HTMLElement>('[data-row-id="live-run"] button.cv-tool.is-toggle')!;
      scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -1, bubbles: true }));
      scroller.scrollTop += toggle.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 200;
      scroller.dispatchEvent(new Event("scroll"));
    });
    await settle(page);
    expect(await atLatest(page)).toBe(false);
    const before = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const above = document.querySelector<HTMLElement>('[data-row-id="t7-answer"]')!;
      above.dataset.aboveProbe = "true";
      return {
        scrollTop: scroller.scrollTop,
        scrollHeight: scroller.scrollHeight,
        aboveTop: above.getBoundingClientRect().top,
      };
    });
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);
    expect(
      await page.locator("[data-probe]").evaluate((node) => {
        const box = node.getBoundingClientRect();
        return node.contains(document.elementFromPoint(box.left + 24, box.top + box.height / 2));
      }),
    ).toBe(true);
    const opened = await clickAndWatch(page);
    await settle(page);
    const after = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const above = document.querySelector<HTMLElement>("[data-above-probe]")!;
      return {
        scrollTop: scroller.scrollTop,
        scrollHeight: scroller.scrollHeight,
        aboveTop: above.getBoundingClientRect().top,
      };
    });
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.threadAnimations).toBe(0);
    expect(opened.moved).toBeLessThanOrEqual(1);
    expect(after.scrollTop).toBeCloseTo(before.scrollTop, 0);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight);
    expect(after.aboveTop).toBeCloseTo(before.aboveTop, 0);
    await page.close();
  });

  test("bottom room survives upward scrolling before a collapse is measured", async () => {
    const page = await open("no-preference");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);
    await clickAndWatch(page);
    const expandedEnd = await scrollHeight(page);
    // Deliver reader intent and a scroll synchronously with the close, before ResizeObserver
    // can report the shrinking body. This releases the line hold but must not release its room.
    await page.evaluate(() => {
      const toggle = document.querySelector<HTMLElement>("[data-probe]")!;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      toggle.click();
      scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -160, bubbles: true }));
      scroller.scrollTop -= 160;
      scroller.dispatchEvent(new Event("scroll"));
    });
    await settle(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("false");
    expect(await atLatest(page)).toBe(false);
    expect(await scrollHeight(page)).toBe(expandedEnd);
    await page.mouse.wheel(0, 10_000);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    expect(await scrollHeight(page)).toBe(expandedEnd);
    await page.close();
  });

  test("a tool toggle just above the end reacquires bottom follow, and user scroll cancels its motion", async () => {
    const page = await open("no-preference");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: -3, bubbles: true }));
      node.scrollTop -= 3;
    });
    await settle(page);
    await probe(page, '[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]');
    const opened = await clickAndWatch(page);
    expect(opened.bottomDrift).toBeLessThanOrEqual(3);
    expect(opened.threadAnimations).toBe(1);
    expect(await atLatest(page)).toBe(true);
    // Dispatch the reversal and scroll in one task so the cancellation cannot miss a short animation.
    await page.evaluate(async () => {
      document.querySelector<HTMLElement>("[data-probe]")!.click();
      await window.cmuxPaintFrame();
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: -100, bubbles: true }));
      node.scrollTop -= 100;
    });
    await settle(page);
    expect(await atLatest(page)).toBe(false);
    expect(await page.locator("[data-bottom-fold]").count()).toBe(0);
    expect(await page.locator(".acpmux-thread").evaluate((node) => node.getAnimations().length)).toBe(0);
    await page.close();
  });

  test("a finished turn's Worked for opened at the latest row pins the bottom", async () => {
    const page = await open("no-preference");
    await show(page, done);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    await probe(page, `[data-row-id="worked-t7-user"] button.cv-worked`);
    const opened = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.bottomDrift).toBeLessThanOrEqual(2);
    expect(await atLatest(page)).toBe(true);
    expect(await page.locator('[data-row-id="t7-run"]').count()).toBe(1);
    await page.close();
  });

  test("empty and zero-width replies add no vertical gap between tool groups", async () => {
    const page = await open("reduce");
    const rows = (withInvisible: boolean) => [
      row("spacing-user", "user", "Run both checks."),
      row("spacing-first", "activity", undefined, { items: [read("spacing-first-tool")] }),
      ...(withInvisible
        ? [row("spacing-empty", "assistant", ""), row("spacing-zero", "assistant", "\u200B\u200C\u200D\uFEFF\u2060")]
        : []),
      row("spacing-second", "activity", undefined, { items: [read("spacing-second-tool")] }),
      row("spacing-answer", "assistant", "Both checks passed."),
      row("spacing-summary", "turnSummary", undefined, { status: "completed", durationMs: 9_000 }),
    ];
    const gapAfterOpenFold = async (withInvisible: boolean) => {
      await show(page, rows(withInvisible));
      await settle(page);
      const fold = page.locator('[data-row-id="worked-spacing-user"] .cv-worked');
      if ((await fold.getAttribute("aria-expanded")) !== "true") await fold.click();
      await settle(page);
      return page.evaluate(() => {
        const first = document.querySelector<HTMLElement>('[data-row-id="spacing-first"]');
        const second = document.querySelector<HTMLElement>('[data-row-id="spacing-second"]');
        if (!first || !second) throw new Error("tool groups were not mounted");
        const a = first.getBoundingClientRect();
        const b = second.getBoundingClientRect();
        return {
          gap: b.top - a.bottom,
          emptyRows: document.querySelectorAll('[data-row-id="spacing-empty"], [data-row-id="spacing-zero"]').length,
        };
      });
    };
    const normal = await gapAfterOpenFold(false);
    const withInvisible = await gapAfterOpenFold(true);
    expect(withInvisible.emptyRows).toBe(0);
    expect(Math.abs(withInvisible.gap - normal.gap)).toBeLessThanOrEqual(0.5);
    await page.close();
  });

  test("a completed turn keeps the reply before a personal steer visible across fold toggles", async () => {
    const page = await open("reduce");
    await show(page, [
      ...done,
      row("steer-user", "user", "Read the log."),
      row("steer-work-a", "activity", undefined, { items: [read("before-steer")] }),
      row("steer-answer-a", "assistant", "Reply A, before the steer."),
      row("steer-input", "user", "Also check the tests.", { steer: "landed" }),
      row("steer-work-b", "activity", undefined, { items: [read("after-steer")] }),
      row("steer-answer-b", "assistant", "Reply B, the final answer."),
      row("steer-summary", "turnSummary", undefined, { status: "completed", durationMs: 9_000 }),
    ]);
    await settle(page);
    const line = page.locator('[data-row-id="worked-steer-user"] .cv-worked');
    const visibleDialogue = async () => {
      for (const id of ["steer-answer-a", "steer-input", "steer-answer-b"])
        expect(await page.locator(`[data-row-id="${id}"]`).isVisible()).toBe(true);
    };
    expect(await line.getAttribute("aria-expanded")).toBe("false");
    await visibleDialogue();
    await line.click();
    await settle(page);
    expect(await line.getAttribute("aria-expanded")).toBe("true");
    await visibleDialogue();
    await line.click();
    await settle(page);
    expect(await line.getAttribute("aria-expanded")).toBe("false");
    await visibleDialogue();
    await page.close();
  });

  test("completion folds received reports without remounting the answer, and keeps one-click open state", async () => {
    const page = await open("reduce");
    const reports = Array.from({ length: 24 }, (_, index) =>
      row(`received-${index}`, "user", `Report ${index + 1}: the focused checks passed.`, {
        steer: "landed",
        promptId: `report-${index}`,
        incoming: {
          kind: "message",
          message: {
            name: `worker-${index + 1}`,
            text: `Report ${index + 1}: the focused checks passed.`,
            raw: `Report ${index + 1}: the focused checks passed.`,
          },
        },
      }),
    );
    const pending = [
      ...Array.from({ length: 30 }, (_, index) => turn(index + 100)).flat(),
      row("completed-user", "user", "Collect the reports and summarize the result."),
      row("completed-progress", "assistant", "I will collect each worker's result before the final answer."),
      ...reports,
      row("completed-answer", "assistant", "All 24 reports are in. The focused checks passed."),
    ];
    await show(page, pending);
    await settle(page);
    await page.evaluate(() => {
      const answer = document.querySelector('[data-row-id="completed-answer"]')!;
      if (!answer) throw new Error("the live answer was not mounted");
      (window as unknown as { savedAnswer: Element }).savedAnswer = answer;
    });
    const completed = [
      ...pending,
      row("completed-summary", "turnSummary", undefined, { status: "completed", durationMs: 282_000 }),
    ];
    await show(page, completed);
    await settle(page);
    expect(
      await page.evaluate(
        () =>
          document.querySelector('[data-row-id="completed-answer"]') ===
          (window as unknown as { savedAnswer: Element }).savedAnswer,
      ),
    ).toBe(true);
    expect(await page.locator('[data-row-id^="received-"]').count()).toBe(0);
    const line = page.locator('[data-row-id="worked-completed-user"] .cv-worked');
    expect(await line.getAttribute("aria-expanded")).toBe("false");
    await probe(page, '[data-row-id="worked-completed-user"] .cv-worked');
    const opened = await clickAndWatch(page);
    expect(opened.bottomDrift).toBeLessThanOrEqual(2);
    expect(await atLatest(page)).toBe(true);
    expect(await line.getAttribute("aria-expanded")).toBe("true");
    const position = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const position = scroller.scrollTop;
      scroller.scrollTop = 0;
      return position;
    });
    await settle(page);
    expect(await line.count()).toBe(0);
    await page.evaluate((position) => {
      document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = position;
    }, position);
    await settle(page);
    expect(await line.getAttribute("aria-expanded")).toBe("true");
    await show(
      page,
      completed.map((entry) => ({ ...entry })),
    );
    await settle(page);
    expect(await line.getAttribute("aria-expanded")).toBe("true");
    await line.click();
    await settle(page);
    expect(await line.getAttribute("aria-expanded")).toBe("false");
    expect(await page.locator('[data-row-id^="received-"]').count()).toBe(0);
    await page.close();
  });

  test("loading the older prompt keeps the provisional fold open and the first click closes it", async () => {
    const page = await open("no-preference");
    const rows = [
      row("older-prompt", "user", "Check the retry path."),
      row("loaded-steer", "user", "And the tests.", { steer: "landed" }),
      row("loaded-tool", "activity", undefined, { items: [read("retry")] }),
      row("loaded-answer", "assistant", "The retry tests passed."),
      row("loaded-end", "turnSummary", undefined, { status: "completed" }),
    ];
    await show(page, rows.slice(1));
    await settle(page);
    await page.locator('[data-row-id="worked-loaded-steer"] .cv-worked').click();
    await show(page, rows);
    await settle(page);
    const line = page.locator('[data-row-id="worked-older-prompt"] .cv-worked');
    expect(await line.getAttribute("aria-expanded")).toBe("true");
    expect(await line.getAttribute("aria-controls")).toContain("loaded-tool");
    const phase = page.evaluate(
      () =>
        new Promise<string | null>((resolve) => {
          document.addEventListener(
            "click",
            () => resolve(document.querySelector(".acpmux-thread")?.getAttribute("data-turn-fold") ?? null),
            { once: true },
          );
        }),
    );
    await line.click();
    expect(await phase).toBe("close");
    await settle(page);
    expect(await line.getAttribute("aria-expanded")).toBe("false");
    expect(await page.locator('[data-row-id="loaded-tool"]').count()).toBe(0);
    await page.close();
  });

  test("mid-transcript, Worked for opens and closes with its line on its pixel", async () => {
    const page = await open("no-preference");
    await show(page, done);
    await settle(page);
    // Up the transcript, with turn 3's line about a third of the way down the view.
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let step = 0; step < 40 && !document.querySelector('[data-row-id="worked-t3-user"]'); step += 1) {
        scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight / 2);
        scroller.dispatchEvent(new Event("scroll"));
      }
    });
    await settle(page);
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const line = document.querySelector<HTMLElement>('[data-row-id="worked-t3-user"] button.cv-worked')!;
      scroller.scrollTop += line.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 200;
    });
    await settle(page);
    expect(await atLatest(page)).toBe(false);
    await probe(page, `[data-row-id="worked-t3-user"] button.cv-worked`);
    const worked = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(worked.moved).toBeLessThanOrEqual(1);
    await settle(page);
    await page.evaluate(() => document.querySelector("[data-probe]")?.removeAttribute("data-probe"));

    await probe(page, `[data-row-id="worked-t3-user"] button.cv-worked`);
    const workedClosed = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("false");
    expect(workedClosed.moved).toBeLessThanOrEqual(1);
    await settle(page);
    // No copy of a hidden row is left behind, and the closed turn is one line again.
    expect(await page.locator(".acpmux-row--fold-ghost").count()).toBe(0);
    expect(await page.locator('[data-row-id="t3-run"]').count()).toBe(0);
    await page.close();
  });

  // Every kind of collapsible, opened and closed mid-transcript: the line the reader clicked stays on
  // its pixel (Show more holds the bubble's top: the text grows below it), and no element ever runs
  // two animations at once (Leo 2026-10-22: "a few animations that didnt quite work for collapsing
  // and expanding wrt tool calls and stufff").
  const longPrompt = Array.from({ length: 24 }, (_, line) => `${line + 1}. The uploader retries on a 5xx.`).join("\n");
  const execute = (id: string, command: string) => ({
    kind: "tool",
    text: "",
    tool: { id, title: command, kind: "execute", status: "completed", command, output: "3 pass\n0 fail", exitCode: 0 },
  });
  const kinds: Row[] = [
    row("k-user", "user", longPrompt),
    row("k-run", "activity", undefined, {
      items: [
        {
          kind: "thought",
          text: "Check the retry wrapper first.\n\nIt swallows the status.",
          startedAt: 0,
          endedAt: 9_000,
        },
        read("k-read"),
        execute("k-cmd-a", "bun test src/net"),
        execute("k-cmd-b", "bun test src/net --watch"),
      ],
    }),
    // Enough below the prompt that Show less, held at its button, never meets the end of the transcript.
    row("k-answer", "assistant", paragraphs(12)),
  ];
  /// Each kind: its toggle (by structure, not by label: the harness page loads no string table, so labels
  /// are keys), and for Show more what holds still while it opens.
  const run = '[data-row-id="k-run"] button.cv-tool.is-toggle';
  const cases: { name: string; toggle: string; text?: string; not?: string; held?: string }[] = [
    { name: "a thought", toggle: `${run}.cv-thought` },
    { name: "a tool call", toggle: `${run}:not(.cv-thought):not(.cv-command)`, text: "k-read" },
    { name: "a command group", toggle: `${run}:not(.cv-thought):not(.cv-command)`, not: "k-read" },
    {
      name: "Show more",
      toggle: '[data-row-id="k-user"] .cv-user__more',
      held: `[data-row-id="k-user"] .cv-user__bubble`,
    },
  ];
  for (const one of cases)
    test(`${one.name} opens and closes with its line on its pixel and one animation per element`, async () => {
      const page = await open("no-preference");
      await show(page, [...done, ...kinds]);
      await settle(page);
      // Marks the toggle (`data-toggle`) and puts it 200 px down the view, away from either end.
      const mark = () =>
        page.evaluate(({ toggle, text, not }) => {
          for (const node of document.querySelectorAll("[data-toggle]")) node.removeAttribute("data-toggle");
          const found = [...document.querySelectorAll<HTMLElement>(toggle)].find(
            (node) =>
              node.hasAttribute("aria-expanded") &&
              (!text || node.textContent?.includes(text)) &&
              !(not && node.textContent?.includes(not)),
          )!;
          found.dataset.toggle = "true";
          return found.getAttribute("aria-expanded") === "true";
        }, one);
      // A kind can start open (the latest command group does), so the first click closes it.
      const startsOpen = await mark();
      for (const opening of [!startsOpen, startsOpen]) {
        await mark();
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const toggle = document.querySelector<HTMLElement>("[data-toggle]")!;
          scroller.scrollTop += toggle.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 200;
        });
        await settle(page);
        const at = await page.evaluate(() => {
          const box = document.querySelector<HTMLElement>("[data-toggle]")!.getBoundingClientRect();
          return { x: box.left + Math.min(24, box.width / 2), y: box.top + box.height / 2 };
        });
        await page.evaluate(() => document.querySelector("[data-probe]")?.removeAttribute("data-probe"));
        // Show more holds the bubble's top while the text grows below it; Show less holds the button.
        await probe(page, opening && one.held ? one.held : "[data-toggle]");
        const watched = await clickAndWatch(page, 450, at);
        expect({ opening, held: watched.moved <= 1 }).toEqual({ opening, held: true });
        expect({ opening, stacked: Math.min(watched.stacked, 2) }).toEqual({ opening, stacked: 1 });
        await settle(page);
        await mark();
        expect(await page.locator("[data-toggle]").getAttribute("aria-expanded")).toBe(String(opening));
      }
      await page.close();
    });

  test("Show less on a prompt several screens tall, with motion off, keeps its button on its pixel", async () => {
    const page = await open("reduce");
    const tall = Array.from({ length: 400 }, (_, line) => `${line + 1}. The uploader retries on a 5xx.`).join("\n");
    await show(page, [
      ...done,
      row("tall-user", "user", tall),
      ...done.map((one) => ({ ...one, id: `after-${one.id}` })),
    ]);
    await settle(page);
    const button = '[data-row-id="tall-user"] .cv-user__more';
    // The prompt sits mid-transcript, so the view first walks up until its row is mounted, then puts
    // the button 200 px down. Rows that mount on the way are measured and shift it, so it tries again
    // until the button rests there.
    const place = async () => {
      for (let attempt = 0; attempt < 6; attempt += 1) {
        await page.evaluate(async (query) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          for (let step = 0; step < 40 && !document.querySelector(query); step += 1) {
            scroller.scrollTop -= scroller.clientHeight / 2;
            await window.cmuxPaintFrame();
          }
          const more = document.querySelector<HTMLElement>(query)!;
          scroller.scrollTop += more.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 200;
        }, button);
        await settle(page);
        const off = await page.evaluate((query) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const top = document.querySelector<HTMLElement>(query)?.getBoundingClientRect().top;
          return top === undefined ? Infinity : Math.abs(top - scroller.getBoundingClientRect().top - 200);
        }, button);
        if (off <= 1) return;
      }
    };
    await place();
    await page.locator(button).click();
    await settle(page);
    expect(await page.locator(button).getAttribute("aria-expanded")).toBe("true");
    await place();
    await page.evaluate(() => document.querySelector("[data-probe]")?.removeAttribute("data-probe"));
    await probe(page, button);
    const closed = await clickAndWatch(page, 250);
    expect(closed.moved).toBeLessThanOrEqual(1);
    expect(await page.locator(button).getAttribute("aria-expanded")).toBe("false");
    expect(Math.abs((await probedTop(page)) - closed.top)).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("under Reduce Motion a tool call opens at once and still pins the bottom", async () => {
    const page = await open("reduce");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);
    const opened = await clickAndWatch(page, 250);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.folded).toBe(false);
    expect(opened.bottomDrift).toBeLessThanOrEqual(2);
    expect(await atLatest(page)).toBe(true);
    await page.close();
  });
});
