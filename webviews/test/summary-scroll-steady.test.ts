// The right-hand card (the Summary card, and Session Info when Debug Settings `agent.inspector` is on)
// stays still while the chat scrolls (Leo, 2026-10-25: "session summary on top right flickers when im
// scrolling thru the chat"). Over 100 painted frames of wheel scrolling through a long chat, nothing in
// the card changes: no node is added, removed or re-rendered with new text, no attribute flips, and
// its box neither moves nor resizes. The header's Summary toggle keeps its node and state too.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engines); CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/summary-scroll-steady.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("summary-scroll-steady.test.ts", async () => {
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });

  /// A background command per turn, finished, so the card has Background tasks and Outputs to list.
  const extra = Array.from({ length: 6 }, (_, index) => {
    const id = `bg${index}`;
    const command = `bun run watch:${index}`;
    return [
      [
        "in",
        "tool_call",
        update({
          sessionUpdate: "tool_call",
          toolCallId: id,
          title: command,
          kind: "execute",
          status: "in_progress",
          rawInput: { command, run_in_background: true, description: `Watcher ${index}` },
        }),
      ],
      [
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          rawOutput: `Command running in background with ID: ${id}`,
        }),
      ],
    ] as [string, string, Record<string, unknown>][];
  }).flat();

  /// The chat's first turn, far above what attach sends a paged chat: it ran the background commands
  /// and wrote the file the card lists, so they arrive only once the reader scrolls up to them.
  const writeNotes = [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: "w1",
      title: "Write notes.md",
      kind: "edit",
      status: "completed",
      locations: [{ path: "/home/dev/cmux/notes.md" }],
      rawInput: { file_path: "/home/dev/cmux/notes.md", content: "notes" },
    }),
  ] as [string, string, Record<string, unknown>];
  const firstTurn = [
    ["mux", "user_message", { text: "Start the watchers" }],
    ["mux", "turn_started", {}],
    ...extra,
    writeNotes,
    ["mux", "turn_result", { status: "completed" }],
  ] as [string, string, Record<string, unknown>][];
  /// A first turn that only edited a file: paged in under a card that already shows, it adds Changes.
  const editTurn = [
    ["mux", "user_message", { text: "Write the notes" }],
    ["mux", "turn_started", {}],
    writeNotes,
    ["mux", "turn_result", { status: "completed" }],
  ] as [string, string, Record<string, unknown>][];
  setDefaultTimeout(150_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`summary-scroll-steady: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("summary scroll steady", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  let paged: Awaited<ReturnType<typeof papercutPane>> | undefined;
  let edited: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, { turns: 40, running: true, extra });
    // A long chat whose attach sends only its newest records: scrolling up pages the rest in.
    paged = await papercutPane(() => current!, { turns: 60, running: false, lead: firstTurn, attachPage: 40 });
    // The same, with background commands on its latest turn: the card shows from the start, and the
    // only edit (so the card's Changes) is in the first turn, above what attach sends.
    edited = await papercutPane(() => current!, { turns: 60, running: false, extra, lead: editTurn, attachPage: 40 });
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
    await paged?.close();
    await edited?.close();
  });

  /// Waits for the finite animations (an opening card's slide); a running turn's spinner never ends.
  const settle = (page: Page) =>
    page.evaluate(async () => {
      const finite = document
        .getAnimations()
        .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      await Promise.all(finite.map((animation) => animation.finished.catch(() => undefined)));
    });

  /// Watches `selector` (the card) and the header's summary toggle across 100 frames of wheel scrolling
  /// up then down; returns what changed in them.
  const scrollAndWatch = (page: Page, selector: string, step = 60) =>
    page.evaluate(
      async ([selector, step]) => {
        const card = document.querySelector<HTMLElement>(selector)!;
        const toggle = document.querySelector<HTMLElement>(".acpmux-summary-button, .acpmux-session-info-toggle");
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const describe = (node: Node) => {
          const element = node instanceof Element ? node : node.parentElement;
          return element ? `${element.tagName.toLowerCase()}.${[...element.classList].join(".")}` : "#text";
        };
        const changes: string[] = [];
        // A running command's elapsed time ticks once a second by design (useNow): that is a clock,
        // not the card changing under the scroll.
        const clock = (node: Node) =>
          !!(node instanceof Element ? node : node.parentElement)?.closest(
            ".acpmux-summary-meta, .acpmux-session-info-task__time, .acpmux-session-info-server__time",
          );
        const observer = new MutationObserver((records) => {
          for (const record of records) {
            if (record.type === "characterData" && clock(record.target)) continue;
            if (record.type === "childList" && clock(record.target) && record.target.textContent) continue;
            if (record.type === "attributes")
              changes.push(`attr ${record.attributeName} on ${describe(record.target)}`);
            else if (record.type === "characterData") changes.push(`text in ${describe(record.target)}`);
            else {
              for (const node of record.addedNodes) changes.push(`added ${describe(node)}`);
              for (const node of record.removedNodes) changes.push(`removed ${describe(node)}`);
            }
          }
        });
        const watch = { attributes: true, childList: true, characterData: true, subtree: true };
        observer.observe(card, watch);
        if (toggle) observer.observe(toggle, watch);
        // The card's own node, and the toggle's, must survive (a remount reads as a blink).
        const parent = card.parentElement!;
        const boxes = new Set<string>();
        const opacities = new Set<string>();
        let replaced = false;
        let lowest = scroller.scrollTop;
        const read = () => {
          lowest = Math.min(lowest, scroller.scrollTop);
          if (!card.isConnected || (toggle && !toggle.isConnected)) replaced = true;
          const box = card.getBoundingClientRect();
          boxes.add(`${Math.round(box.x)},${Math.round(box.y)},${Math.round(box.width)},${Math.round(box.height)}`);
          opacities.add(getComputedStyle(card).opacity);
        };
        read();
        const start = scroller.scrollTop;
        const frames = 100;
        const errors: string[] = [];
        await new Promise<void>((done) => {
          let frame = 0;
          window.cmuxAfterPaint(
            () => {
              try {
                read();
              } catch (error) {
                errors.push(String(error));
              }
              frame += 1;
              if (frame < frames) return true;
              done();
              return false;
            },
            () => {
              // Up for the first half, back down for the second: 60px a frame, a quick trackpad flick.
              const delta = frame < frames / 2 ? -step : step;
              scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: delta, bubbles: true }));
              scroller.scrollTop += delta;
            },
          );
        });
        observer.disconnect();
        return {
          start,
          lowest,
          end: scroller.scrollTop,
          errors,
          changes: [...new Set(changes)],
          changeCount: changes.length,
          boxes: [...boxes],
          opacities: [...opacities],
          replaced: replaced || !parent.contains(card),
        };
      },
      [selector, step] as const,
    );

  for (const name of browsers.keys()) {
    test(`${name}: the inline Summary card holds still while the chat scrolls`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1400, height: 760 });
      try {
        const card = page.locator("aside.acpmux-summary-card[data-placement=inline]");
        await card.waitFor({ timeout: 10_000 });
        await settle(page);
        const seen = await scrollAndWatch(page, "aside.acpmux-summary-card[data-placement=inline]");
        console.log(`${name} inline summary while scrolling: ${JSON.stringify(seen)}`);
        expect({
          changes: seen.changes,
          boxes: seen.boxes.length,
          opacities: seen.opacities,
          replaced: seen.replaced,
        }).toEqual({ changes: [], boxes: 1, opacities: ["1"], replaced: false });
      } finally {
        await page.close();
      }
    });

    test(`${name}: the Summary popover holds still while the chat scrolls`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 760, height: 760 });
      try {
        await page.locator(".acpmux-summary-button").click();
        const selector = "aside.acpmux-summary-card[data-placement=popover]";
        await page.locator(`${selector}[data-presence=shown]`).waitFor({ timeout: 10_000 });
        await settle(page);
        const seen = await scrollAndWatch(page, selector);
        console.log(`${name} summary popover while scrolling: ${JSON.stringify(seen)}`);
        expect({
          changes: seen.changes,
          boxes: seen.boxes.length,
          opacities: seen.opacities,
          replaced: seen.replaced,
        }).toEqual({ changes: [], boxes: 1, opacities: ["1"], replaced: false });
      } finally {
        await page.close();
      }
    });

    test(`${name}: Session Info holds still while the chat scrolls`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1200, height: 760 });
      try {
        await page.evaluate(() => {
          (
            window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
        });
        const toggle = page.locator("button.acpmux-session-info-toggle");
        await toggle.waitFor({ timeout: 10_000 });
        const selector = "aside.acpmux-session-info";
        if ((await page.locator(selector).count()) === 0) await toggle.click({ force: true });
        await page.locator(`${selector}[data-presence=shown]`).waitFor({ timeout: 10_000 });
        await settle(page);
        const seen = await scrollAndWatch(page, selector);
        console.log(`${name} Session Info while scrolling: ${JSON.stringify(seen)}`);
        expect({
          changes: seen.changes,
          boxes: seen.boxes.length,
          opacities: seen.opacities,
          replaced: seen.replaced,
        }).toEqual({ changes: [], boxes: 1, opacities: ["1"], replaced: false });
      } finally {
        await page.close();
      }
    });

    test(`${name}: the inline Summary card holds still while older history pages in under it`, async () => {
      current = browsers.get(name)!;
      const page = await paged!.open({ width: 1400, height: 760 });
      try {
        await settle(page);
        // A chat whose loaded rows have no summary content reserves the column without drawing it.
        const selector = "aside.acpmux-summary-card[data-placement=inline]";
        await page.locator(selector).first().waitFor({ state: "attached", timeout: 10_000 });
        const before = await page
          .locator(selector)
          .first()
          .evaluate((card) => ({
            reserve: card.classList.contains("acpmux-summary-card--reserve"),
            text: card.textContent,
          }));
        const seen = await scrollAndWatch(page, selector, 400);
        // Once the scroll settles, what it paged in reaches the card, in one change.
        await page.waitForFunction(
          (selector) => document.querySelector(selector)?.textContent?.includes("watch:0"),
          selector,
        );
        const after = await page
          .locator(selector)
          .first()
          .evaluate((card) => ({
            reserve: card.classList.contains("acpmux-summary-card--reserve"),
            text: card.textContent,
          }));
        console.log(
          `${name} inline summary while history pages in: ${JSON.stringify({ before, after, seen, methods: paged!.methods.filter((method) => method === "_acpmux/events").length })}`,
        );
        expect({
          changes: seen.changes,
          boxes: seen.boxes.length,
          replaced: seen.replaced,
          pagedToTop: seen.lowest,
          before: before.reserve,
          after: after.reserve,
        }).toEqual({ changes: [], boxes: 1, replaced: false, pagedToTop: 0, before: true, after: false });
        expect(after.text).toContain("watch:0");
      } finally {
        await page.close();
      }
    });

    test(`${name}: a showing Summary card holds its Changes while an older edit pages in under it`, async () => {
      current = browsers.get(name)!;
      const page = await edited!.open({ width: 1400, height: 760 });
      try {
        await settle(page);
        const selector = "aside.acpmux-summary-card[data-placement=inline]";
        await page.waitForFunction(
          (selector) => document.querySelector(selector)?.textContent?.includes("watch:0"),
          selector,
        );
        const read = () =>
          page
            .locator(selector)
            .first()
            .evaluate((card) => ({
              reserve: card.classList.contains("acpmux-summary-card--reserve"),
              text: card.textContent ?? "",
            }));
        const before = await read();
        const seen = await scrollAndWatch(page, selector, 400);
        // Once the scroll settles, the paged-in edit reaches the card's Changes, in one change.
        await page.waitForFunction(
          (selector) => document.querySelector(selector)?.textContent?.includes("Changes"),
          selector,
        );
        const after = await read();
        console.log(`${name} showing summary while an older edit pages in: ${JSON.stringify({ before, after, seen })}`);
        expect({
          changes: seen.changes,
          boxes: seen.boxes.length,
          replaced: seen.replaced,
          pagedToTop: seen.lowest,
          reserve: before.reserve,
        }).toEqual({ changes: [], boxes: 1, replaced: false, pagedToTop: 0, reserve: false });
        expect(before.text).not.toContain("Changes");
        expect(after.text).toContain("Changes");
      } finally {
        await page.close();
      }
    });

    test(`${name}: Session Info holds still while older history pages in under it`, async () => {
      current = browsers.get(name)!;
      const page = await paged!.open({ width: 1200, height: 760 });
      try {
        await page.evaluate(() => {
          (
            window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
        });
        const toggle = page.locator("button.acpmux-session-info-toggle");
        await toggle.waitFor({ timeout: 10_000 });
        const selector = "aside.acpmux-session-info";
        if ((await page.locator(selector).count()) === 0) await toggle.click({ force: true });
        await page.locator(`${selector}[data-presence=shown]`).waitFor({ timeout: 10_000 });
        await settle(page);
        const seen = await scrollAndWatch(page, selector, 400);
        await page.waitForFunction(
          (selector) => document.querySelector(selector)?.textContent?.includes("watch:0"),
          selector,
        );
        const after = await page.locator(selector).evaluate((panel) => panel.textContent ?? "");
        expect(after).toContain("watch:0");
        console.log(
          `${name} Session Info while history pages in: ${JSON.stringify({ seen, methods: paged!.methods.filter((method) => method === "_acpmux/events").length })}`,
        );
        expect({
          changes: seen.changes,
          boxes: seen.boxes.length,
          replaced: seen.replaced,
          pagedToTop: seen.lowest,
        }).toEqual({ changes: [], boxes: 1, replaced: false, pagedToTop: 0 });
      } finally {
        await page.close();
      }
    });
  }
});
