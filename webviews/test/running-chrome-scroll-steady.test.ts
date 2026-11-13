// l10n-allow-file: test fixture commands, not shipped UI.
// What a running chat shows around its transcript (the running tray above the composer, the live
// "Working" line, Session Info) never flickers while the reader scrolls (Leo, 2026-11-03: "we NEED
// to have "dynamic" content such as the bottom running area + the session info thing not flicker
// EVER when im scrolling"). Over 100 painted frames of wheel scrolling a running chat up and back
// down, with background commands running, none of them changes: no node is added, removed or
// re-rendered with new text (a running command's ticking clock aside), no attribute flips, no
// animation restarts, its box holds, its opacity stays 1 and its node is never replaced.
//
// The page is the pane's dev entry talking to a stand-in acpmux (support/papercutChat.ts). Real
// Chromium and WebKit; CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/running-chrome-scroll-steady.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane, type PapercutStep } from "./support/papercutChat";

await requireBrowserLane("running-chrome-scroll-steady.test.ts", async () => {
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  /// Two background commands still running in the running turn: the tray shows them.
  const extra: PapercutStep[] = ["dev", "watch"].flatMap((id) => {
    const command = `bun run ${id}`;
    return [
      [
        "in",
        "tool_call",
        update({
          sessionUpdate: "tool_call",
          toolCallId: `bg-${id}`,
          title: command,
          kind: "execute",
          status: "in_progress",
          rawInput: { command, run_in_background: true, description: `Run ${id}` },
        }),
      ],
      [
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: `bg-${id}`,
          status: "completed",
          rawOutput: `Command running in background with ID: bg-${id}`,
        }),
      ],
    ] as PapercutStep[];
  });

  setDefaultTimeout(150_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`running-chrome-scroll-steady: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("running chrome scroll steady", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, { turns: 40, running: true, extra, ready: ".acpmux-running-tray" });
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// The surfaces watched, by selector: each must be on the page when the scroll starts.
  const SURFACES = {
    tray: ".acpmux-running-tray",
    sessionInfo: "aside.acpmux-session-info",
  };

  /// Watches every surface across 100 frames of wheel scrolling up then down; returns, per surface,
  /// what changed in it.
  const scrollAndWatch = (page: Page) =>
    page.evaluate(async (surfaces) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const describe = (node: Node) => {
        const element = node instanceof Element ? node : node.parentElement;
        return element ? `${element.tagName.toLowerCase()}.${[...element.classList].join(".")}` : "#text";
      };
      // A running command's elapsed time ticks once a second by design (useNow): a clock, not the
      // surface changing under the scroll.
      const clock = (node: Node) =>
        !!(node instanceof Element ? node : node.parentElement)?.closest(
          ".acpmux-summary-meta, .acpmux-session-info-task__time, .acpmux-session-info-server__time, .acpmux-running-tray__time, [data-clock]",
        );
      type Seen = {
        node: HTMLElement;
        parent: HTMLElement;
        changes: string[];
        boxes: Set<string>;
        opacities: Set<string>;
        animations: Set<Animation>;
        restarted: string[];
        replaced: boolean;
      };
      const seen: Record<string, Seen> = {};
      const observers: MutationObserver[] = [];
      for (const [name, selector] of Object.entries(surfaces)) {
        const node = document.querySelector<HTMLElement>(selector);
        if (!node) throw new Error(`no ${name} (${selector}) on the page`);
        const entry: Seen = {
          node,
          parent: node.parentElement!,
          changes: [],
          boxes: new Set(),
          opacities: new Set(),
          animations: new Set(node.getAnimations({ subtree: true })),
          restarted: [],
          replaced: false,
        };
        seen[name] = entry;
        const observer = new MutationObserver((records) => {
          for (const record of records) {
            if (record.type === "characterData" && clock(record.target)) continue;
            if (record.type === "childList" && clock(record.target) && record.target.textContent) continue;
            if (record.type === "attributes")
              entry.changes.push(`attr ${record.attributeName} on ${describe(record.target)}`);
            else if (record.type === "characterData") entry.changes.push(`text in ${describe(record.target)}`);
            else {
              for (const added of record.addedNodes) entry.changes.push(`added ${describe(added)}`);
              for (const removed of record.removedNodes) entry.changes.push(`removed ${describe(removed)}`);
            }
          }
        });
        observer.observe(node, { attributes: true, childList: true, characterData: true, subtree: true });
        observers.push(observer);
      }
      const read = () => {
        for (const entry of Object.values(seen)) {
          if (!entry.node.isConnected || !entry.parent.contains(entry.node)) entry.replaced = true;
          const box = entry.node.getBoundingClientRect();
          entry.boxes.add(
            `${Math.round(box.x)},${Math.round(box.y)},${Math.round(box.width)},${Math.round(box.height)}`,
          );
          entry.opacities.add(getComputedStyle(entry.node).opacity);
          // An animation that was not running when the scroll began is one the scroll (re)started:
          // a spinner or shimmer restarting reads as a blink.
          for (const animation of entry.node.getAnimations({ subtree: true })) {
            if (entry.animations.has(animation)) continue;
            entry.animations.add(animation);
            const target = (animation.effect as KeyframeEffect | null)?.target;
            const label = (animation as CSSAnimation).animationName ?? (animation as CSSTransition).transitionProperty;
            entry.restarted.push(`${label ?? "animation"} on ${target ? describe(target) : "?"}`);
          }
        }
      };
      // A row the scroll brings back (the live "Working" line included) must not play an enter, fade
      // or shimmer restart as it comes into view: the transcript's own finite animations, by row.
      const known = new Set(scroller.getAnimations({ subtree: true }));
      const rowAnimations: string[] = [];
      // The prompt rail answers the scroll by design (its ticks light as their prompts pass), and a
      // shared loop (the live line's shimmer) that mounts again is fine as long as it paints its first
      // frame on the shared phase (ui/spinnerClock.ts), where a restart cannot be seen.
      const shared = new Set(["cmux-spin", "cmux-breathe", "cmux-shimmer", "cmux-shimmer-band", "cmux-shimmer-lit"]);
      const readRows = () => {
        const now = document.timeline.currentTime as number;
        for (const animation of scroller.getAnimations({ subtree: true })) {
          if (known.has(animation)) continue;
          known.add(animation);
          const target = (animation.effect as KeyframeEffect | null)?.target;
          if (target instanceof Element && target.closest(".acpmux-minimap")) continue;
          const name = (animation as CSSAnimation).animationName;
          const label = name ?? (animation as CSSTransition).transitionProperty;
          if (name && shared.has(name)) {
            // The drawn phase is the iteration's progress: a shimmer phased by a negative delay
            // (ui/spinnerClock.ts `setLoopPhase`) is that far ahead of its currentTime.
            const timing = animation.effect!.getComputedTiming();
            const period = Number(timing.duration);
            const phase = (performance.timeOrigin + now) % period;
            const drawn = Number(timing.progress) * period;
            const off = Math.min(Math.abs(phase - drawn), period - Math.abs(phase - drawn));
            if (off < 50) continue;
            rowAnimations.push(
              `${label} on ${target ? describe(target) : "?"} ${Math.round(off)}ms off the shared phase`,
            );
            continue;
          }
          rowAnimations.push(`${label ?? "animation"} on ${target ? describe(target) : "?"}`);
        }
      };
      read();
      const start = scroller.scrollTop;
      const frames = 100;
      await new Promise<void>((done) => {
        let frame = 0;
        window.cmuxAfterPaint(
          () => {
            read();
            readRows();
            frame += 1;
            if (frame < frames) return true;
            done();
            return false;
          },
          () => {
            // Up for the first half, back down for the second: 60px a frame, a quick trackpad flick.
            const delta = frame < frames / 2 ? -60 : 60;
            scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: delta, bubbles: true }));
            scroller.scrollTop += delta;
          },
        );
      });
      for (const observer of observers) observer.disconnect();
      return {
        start,
        end: scroller.scrollTop,
        rowAnimations: [...new Set(rowAnimations)],
        surfaces: Object.fromEntries(
          Object.entries(seen).map(([name, entry]) => [
            name,
            {
              changes: [...new Set(entry.changes)],
              boxes: entry.boxes.size,
              opacities: [...entry.opacities],
              restarted: [...new Set(entry.restarted)],
              replaced: entry.replaced,
            },
          ]),
        ),
      };
    }, SURFACES);

  const still = { changes: [], boxes: 1, opacities: ["1"], restarted: [], replaced: false };

  for (const name of browsers.keys()) {
    // 1400: Session Info floats in the gutter; 1000: it pushes the chat; 760: it lies over the chat.
    for (const width of [1400, 1000, 760]) {
      test(`${name} at ${width} px: the running tray and Session Info hold still while the chat scrolls`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 760 });
        try {
          await page.evaluate(() => {
            (
              window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
            ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
          });
          const toggle = page.locator("button.acpmux-session-info-toggle");
          await toggle.waitFor({ timeout: 10_000 });
          if ((await page.locator(SURFACES.sessionInfo).count()) === 0) await toggle.click({ force: true });
          await page.locator(`${SURFACES.sessionInfo}[data-presence=shown]`).waitFor({ timeout: 10_000 });
          await page.locator(SURFACES.tray).waitFor({ timeout: 10_000 });
          await page.evaluate(async () => {
            const finite = document
              .getAnimations()
              .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
            await Promise.all(finite.map((animation) => animation.finished.catch(() => undefined)));
          });
          const result = await scrollAndWatch(page);
          console.log(`${name} ${width}px running chrome while scrolling: ${JSON.stringify(result)}`);
          expect(result.surfaces).toEqual({ tray: still, sessionInfo: still });
          expect(result.rowAnimations).toEqual([]);
        } finally {
          await page.close();
        }
      });
      test(`${name} at ${width} px: the running tray and Session Info paint the same pixels while the chat scrolls`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 760 });
        try {
          await page.evaluate(() => {
            (
              window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
            ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
          });
          const toggle = page.locator("button.acpmux-session-info-toggle");
          await toggle.waitFor({ timeout: 10_000 });
          if ((await page.locator(SURFACES.sessionInfo).count()) === 0) await toggle.click({ force: true });
          await page.locator(`${SURFACES.sessionInfo}[data-presence=shown]`).waitFor({ timeout: 10_000 });
          await page.locator(SURFACES.tray).waitFor({ timeout: 10_000 });
          // The clocks tick by design: hide them so only what the scroll changes shows.
          await page.addStyleTag({
            content:
              ".acpmux-running-tray__time, .acpmux-summary-meta, .acpmux-session-info-task__time, .acpmux-session-info-server__time, [data-clock] { visibility: hidden !important; }",
          });
          await page.evaluate(async () => {
            const finite = document
              .getAnimations()
              .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
            await Promise.all(finite.map((animation) => animation.finished.catch(() => undefined)));
          });
          const scroller = page.locator(".acpmux-scroll");
          const box = (await scroller.boundingBox())!;
          await page.mouse.move(box.x + box.width / 3, box.y + box.height / 3);
          const shots: Record<string, Set<string>> = { tray: new Set(), sessionInfo: new Set() };
          const hash = (bytes: Buffer) => new Bun.CryptoHasher("sha1").update(bytes).digest("hex");
          for (let step = 0; step < 24; step++) {
            await page.mouse.wheel(0, step < 12 ? -90 : 90);
            await page.evaluate(() => window.cmuxPaintFrame());
            for (const [key, selector] of Object.entries(SURFACES))
              shots[key]!.add(hash(await page.locator(selector).screenshot({ animations: "disabled" })));
          }
          const distinct = Object.fromEntries(Object.entries(shots).map(([key, set]) => [key, set.size]));
          console.log(`${name} ${width}px distinct paints while scrolling: ${JSON.stringify(distinct)}`);
          expect(distinct).toEqual({ tray: 1, sessionInfo: 1 });
        } finally {
          await page.close();
        }
      });
    }
  }
});
