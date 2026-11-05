// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// The chat scroll check: Leo's chat scroll repros in one scripted run of the real agent pane, run
// against the source of the nightly he uses (Leo, 2026-11-05: "i meant can you do all of htem", on
// leo-workspace research/2026-11-05-where-we-stand.md, "Chat scroll: one owner, one scripted
// done-when on nightly"). The chat is long and mixed (tool runs, code blocks, long replies), opens on
// its tail and pages older history in as the reader wheels up, while a reply streams below and
// Session Info is open beside it. Every painted frame of the wheel is read, and the run fails on any
// of what he reported:
//
// - Scroll-up history loading (2026-10-26 "im getting flickers and jumps when i scroll up and it's
//   loading new parts of chats that havent been loaded"; "the thumb just jitters like crazy because
//   it's loading upwards"; 2026-10-28 "it tries to slowly jump me towards the bottom"; 2026-10-29
//   "why is it sometimes blocking me from scrolling up further?"; 2026-10-31 "I HATE THE FUCKING
//   FLICKER LOAD IN WHEN I SCROLL UP TO CHATS"): a row on screen moves only by what the wheel asked
//   (support/upwardAnchorTrace.ts), no frame shows a blank band, no row on screen is drawn faded or
//   animating in, the scrollbar's thumb never moves down while the reader goes up, and the wheel's
//   whole distance is applied.
// - Jump to latest (2026-10-28 "when I scroll up, I don't want to see that fucking, like, jump to
//   bottom button be jumping around jittering and flickering like that"): once it shows it shows
//   for good, its box never moves and its opacity never falls.
// - Session Info (2026-10-25 "session summary on top right flickers when im scrolling thru the
//   chat"; 2026-10-31 "WHY DOES THE SESSION INFO FUCKING FLICKER WHEN I SCROLL"): nothing in it is
//   added, removed or re-rendered, its box holds and its opacity stays 1.
//
// The page is the pane's dev entry talking to a stand-in acpmux (support/papercutChat.ts). WebKit is
// the engine the app draws the pane in; Chromium runs too. Run it yourself, never as a CI gate:
// CMUX_BROWSER_TESTS=1 bun test test/chat-scroll-nightly.test.ts (or `cmux-ci test -- ...` off host).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { traceUpwardAnchors } from "./support/upwardAnchorTrace";

await requireBrowserLane("chat-scroll-nightly.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["webkit", webkit],
    ["chromium", chromium],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`chat-scroll-nightly: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("chat scroll nightly check", () => test("no engine", () => {}));
    return;
  }

  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const say = (text: string): PapercutStep => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
  ];
  /// Older turns as a working chat has them: each of a different height, with tool runs, code blocks
  /// and long replies, so rows paged in above the reader measure differently from any estimate.
  const OLDER = 72;
  const lead: PapercutStep[] = [];
  for (let n = 1; n <= OLDER; n++) {
    lead.push(["mux", "user_message", { text: `Older question ${n}: ${"why does the retry wait ".repeat(n % 5)}?` }]);
    lead.push(["mux", "turn_started", {}]);
    for (let call = 0; call < n % 4; call++) {
      const id = `older-${n}-${call}`;
      const command = `rg -n "retry" src/daemon/${call}.ts`;
      lead.push([
        "in",
        "tool_call",
        update({
          sessionUpdate: "tool_call",
          toolCallId: id,
          title: command,
          kind: "execute",
          status: "in_progress",
          rawInput: { command },
        }),
      ]);
      lead.push([
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          rawOutput: Array.from(
            { length: 3 + ((n + call) % 9) },
            (_, line) => `src/daemon/${call}.ts:${line}: retry`,
          ).join("\n"),
        }),
      ]);
    }
    const paragraphs = Array.from(
      { length: 1 + (n % 6) },
      (_, p) =>
        `Older answer ${n}, part ${p + 1}: the checks on the merged head are green, and the retry waits a little ` +
        `longer each time with jitter so two clients never hammer the daemon together.`,
    );
    if (n % 3 === 0)
      paragraphs.push(
        "```ts\n" +
          Array.from(
            { length: 4 + (n % 11) },
            (_, line) => `const wait${line} = backoff(${line}, { jitter: true });`,
          ).join("\n") +
          "\n```",
      );
    if (n % 4 === 1) paragraphs.push(Array.from({ length: 3 + (n % 5) }, (_, item) => `- step ${item + 1}`).join("\n"));
    lead.push(say(paragraphs.join("\n\n")));
    lead.push(["mux", "turn_result", { status: "completed" }]);
  }

  let current: Browser | undefined;
  const browsers = new Map<string, Browser>();
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  type Frame = {
    jump: { shown: boolean; opacity: number; x: number; y: number; w: number; h: number } | null;
    info: { x: number; y: number; w: number; h: number; opacity: number } | null;
    thumb: number;
    scrollHeight: number;
    faded: string[];
    animating: string[];
    live: string[];
  };
  /// Reads every painted frame from now until `stopWatch`: the Jump to latest control, Session Info,
  /// the scrollbar's thumb, and rows on screen drawn faded or running an animation. Session Info's
  /// changes are collected by a MutationObserver (a running clock aside).
  const startWatch = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const info = document.querySelector<HTMLElement>("aside.acpmux-session-info");
      const holder = window as unknown as {
        __scrollWatch?: { frames: Frame[]; infoChanges: string[]; infoNode: Element | null; stop(): void };
      };
      const frames: Frame[] = [];
      const infoChanges: string[] = [];
      const clock = (node: Node) =>
        !!(node instanceof Element ? node : node.parentElement)?.closest(
          ".acpmux-summary-meta, .acpmux-session-info-task__time, .acpmux-session-info-server__time, [data-clock]",
        );
      const name = (node: Node) => {
        const element = node instanceof Element ? node : node.parentElement;
        return element ? `${element.tagName.toLowerCase()}.${[...element.classList].join(".")}` : "#text";
      };
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          if (clock(record.target)) continue;
          if (record.type === "attributes" && record.attributeName === "style" && record.target === info) continue;
          infoChanges.push(`${record.type}:${record.attributeName ?? ""}:${name(record.target)}`);
        }
      });
      if (info) observer.observe(info, { subtree: true, childList: true, characterData: true, attributes: true });
      const box = (element: Element) => {
        const rect = element.getBoundingClientRect();
        return { x: rect.x, y: rect.y, w: rect.width, h: rect.height };
      };
      const stop = window.cmuxAfterPaint(() => {
        const view = scroller.getBoundingClientRect();
        const jump = document.querySelector<HTMLElement>(".acpmux-jump-latest");
        const faded: string[] = [];
        const animating: string[] = [];
        const live: string[] = [];
        for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row")) {
          const rect = row.getBoundingClientRect();
          if (rect.height === 0 || rect.bottom <= view.top || rect.top >= view.bottom) continue;
          const id = row.dataset.rowId ?? "?";
          const visual = row
            .getAnimations({ subtree: true })
            .filter((animation) => animation.playState === "running")
            .filter((animation) => {
              const effect = animation.effect as KeyframeEffect | null;
              // Shimmers and spinners loop by design; a load-in plays once.
              if (!effect || effect.getComputedTiming().iterations === Infinity) return false;
              return effect.getKeyframes().some((frame) => "opacity" in frame || "transform" in frame);
            });
          // A live row's entrance (the streaming reply arriving at the bottom) is not scroll-up
          // loading: reported apart, not held here.
          const LIVE = new Set(["cv-enter", "cv-enter-fade", "cv-message-enter"]);
          const named = (animation: Animation) => {
            const css = (animation as CSSAnimation).animationName;
            if (css) return css;
            const effect = animation.effect as KeyframeEffect | null;
            const target = effect?.target;
            const props = [...new Set((effect?.getKeyframes() ?? []).flatMap((frame) => Object.keys(frame)))]
              .filter((key) => !["offset", "easing", "composite", "computedOffset"].includes(key))
              .join("/");
            return `script(${target ? `${target.tagName.toLowerCase()}.${[...target.classList].join(".")}` : "?"} ${props})`;
          };
          const loading = visual.filter((animation) => !LIVE.has((animation as CSSAnimation).animationName));
          if (loading.length) animating.push(`${id}:${loading.map(named).join("+")}`);
          if (visual.length > loading.length) live.push(id);
          else if (Number(getComputedStyle(row).opacity) < 0.999) faded.push(id);
        }
        frames.push({
          jump: jump
            ? {
                shown: jump.hasAttribute("data-shown"),
                opacity: Number(getComputedStyle(jump).opacity),
                ...box(jump),
              }
            : null,
          info: info?.isConnected ? { ...box(info), opacity: Number(getComputedStyle(info).opacity) } : null,
          thumb:
            scroller.scrollHeight > scroller.clientHeight
              ? (scroller.scrollTop / scroller.scrollHeight) * scroller.clientHeight
              : 0,
          scrollHeight: scroller.scrollHeight,
          faded,
          animating,
          live,
        });
      });
      holder.__scrollWatch = {
        frames,
        infoChanges,
        infoNode: info,
        stop: () => {
          stop();
          observer.disconnect();
        },
      };
    });
  const stopWatch = (page: Page) =>
    page.evaluate(() => {
      const holder = window as unknown as {
        __scrollWatch?: { frames: Frame[]; infoChanges: string[]; infoNode: Element | null; stop(): void };
      };
      const watch = holder.__scrollWatch!;
      watch.stop();
      return {
        frames: watch.frames,
        infoChanges: watch.infoChanges,
        infoReplaced: watch.infoNode !== null && watch.infoNode !== document.querySelector("aside.acpmux-session-info"),
      };
    });

  /// What the reader saw over the frames, as counts the check holds at zero.
  function tally(frames: Frame[]) {
    const from = frames.findIndex((frame) => frame.jump?.shown);
    const shown = from < 0 ? [] : frames.slice(from);
    let jumpFlips = 0;
    let jumpMoves = 0;
    let jumpDips = 0;
    for (let index = 1; index < shown.length; index++) {
      const [a, b] = [shown[index - 1]!.jump, shown[index]!.jump];
      if (!a || !b || a.shown !== b.shown) jumpFlips++;
      else {
        if (Math.abs(a.x - b.x) > 0.5 || Math.abs(a.y - b.y) > 0.5 || Math.abs(a.w - b.w) > 0.5) jumpMoves++;
        if (b.opacity < a.opacity - 0.001) jumpDips++;
      }
    }
    let infoMoves = 0;
    let infoFaded = 0;
    let thumbDown = 0;
    let thumbDownMax = 0;
    const thumbLog: string[] = [];
    for (let index = 1; index < frames.length; index++) {
      const [a, b] = [frames[index - 1]!, frames[index]!];
      if (!a.info !== !b.info) infoMoves++;
      else if (a.info && b.info) {
        if (Math.abs(a.info.x - b.info.x) > 0.5 || Math.abs(a.info.y - b.info.y) > 0.5) infoMoves++;
        if (Math.abs(a.info.w - b.info.w) > 0.5 || Math.abs(a.info.h - b.info.h) > 0.5) infoMoves++;
        if (b.info.opacity < 0.999) infoFaded++;
      }
      // The reader only goes up: the thumb may only go up (or hold).
      if (b.thumb - a.thumb > 1) {
        thumbDown++;
        if (thumbLog.length < 6)
          thumbLog.push(
            `${index}: thumb ${Math.round(a.thumb)}->${Math.round(b.thumb)}, height ${a.scrollHeight}->${b.scrollHeight}`,
          );
        thumbDownMax = Math.max(thumbDownMax, b.thumb - a.thumb);
      }
    }
    return {
      frames: frames.length,
      jumpShown: from >= 0,
      jumpShownAtEnd: frames.at(-1)?.jump?.shown ?? false,
      jumpFlips,
      jumpMoves,
      jumpDips,
      infoOnPage: frames.every((frame) => frame.info !== null),
      infoMoves,
      infoFaded,
      thumbDown,
      thumbDownMax: Math.round(thumbDownMax),
      thumbLog,
      heightChanges: frames.filter(
        (frame, index) => index > 0 && frame.scrollHeight !== frames[index - 1]!.scrollHeight,
      ).length,
      fadedFrames: frames.filter((frame) => frame.faded.length).length,
      animatingFrames: frames.filter((frame) => frame.animating.length).length,
      fadedRows: [...new Set(frames.flatMap((frame) => frame.faded))].slice(0, 8),
      animatingRows: [...new Set(frames.flatMap((frame) => frame.animating))].slice(0, 8),
      liveEntranceRows: [...new Set(frames.flatMap((frame) => frame.live))].slice(0, 8),
    };
  }

  test.each(engines.map(([name]) => name))(
    "%s: wheeling up through older history while a reply streams, nothing on screen jumps or flickers",
    async (name) => {
      current = browsers.get(name)!;
      // A fresh chat per engine (an earlier run's streamed reply would move its tail). A running
      // last turn: the pane follows its tail, and Jump to latest offers "still replying".
      // The summary counts every prompt, the older ones too, as acpmux's does: the pane reserves the
      // room for the unloaded history from it.
      pane = await papercutPane(() => current!, {
        turns: 12,
        running: true,
        lead,
        attachPage: 160,
        session: { turnCount: OLDER + 12 + 1 },
      });
      const page = await pane.open({ width: 1100, height: 760 });
      await page.emulateMedia({ reducedMotion: "no-preference" });
      // Session Info open beside the chat, as Leo has it (the header state the app sends, then its
      // toggle; session-info-overlay-toggle.test.ts), and done entering before the wheel starts.
      await page.evaluate(() =>
        (
          window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
        ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
      );
      const toggle = page.locator("button.acpmux-session-info-toggle");
      await toggle.waitFor({ timeout: 10_000 });
      if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
      await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
      await page.evaluate(() =>
        Promise.all(
          document
            .getAnimations()
            .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
            .map((animation) => animation.finished.catch(() => undefined)),
        ),
      );
      const pagesBefore = pane!.methods.filter((method) => method === "_acpmux/events").length;
      const view = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
      // The reply streams below the reader: a paragraph every 80 ms for the whole run.
      let streamed = 0;
      const stream = setInterval(() => {
        const [dir, kind, msg] = say(
          `Streaming paragraph ${++streamed}: the reader scrolls up while this arrives.\n\n`,
        );
        pane!.record(kind, msg, dir);
      }, 80);
      await startWatch(page);
      // A trackpad's uneven steps, in rounds so older pages land while the wheel is moving.
      const traces = [];
      try {
        for (let round = 0; round < 6; round++)
          traces.push(
            await page.evaluate(traceUpwardAnchors, {
              steps: Array.from({ length: 90 }, (_, frame) => -[18.25, 42.5, 27.75, 56.125][frame % 4]!),
              restFrames: 6,
            }),
          );
      } finally {
        clearInterval(stream);
      }
      const watched = await stopWatch(page);
      const pages = pane!.methods.filter((method) => method === "_acpmux/events").length - pagesBefore;
      const seen = tally(watched.frames);
      const sum = (key: "cancelledWheels" | "missingAnchors" | "blankFrames" | "blankBandFrames" | "overlapFrames") =>
        traces.reduce((total, trace) => total + (trace[key] as number), 0);
      const anchors = {
        frames: traces.reduce((total, trace) => total + trace.frames, 0),
        compared: traces.reduce((total, trace) => total + trace.compared, 0),
        wheelPixels: Math.round(traces.reduce((total, trace) => total + trace.wheelPixels, 0)),
        maxDrift: Math.max(...traces.map((trace) => trace.maxDrift)),
        cancelledWheels: sum("cancelledWheels"),
        missingAnchors: sum("missingAnchors"),
        blankFrames: sum("blankFrames"),
        blankBandFrames: sum("blankBandFrames"),
        overlapFrames: sum("overlapFrames"),
      };
      const summary = {
        engine: name,
        pages,
        streamed,
        anchors,
        ...seen,
        infoChanges: watched.infoChanges.length,
        infoChangeKinds: [...new Set(watched.infoChanges)].slice(0, 8),
        infoReplaced: watched.infoReplaced,
      };
      // One short line per entry: the hosted log cuts long lines.
      for (const [key, value] of Object.entries(summary))
        console.info(`chat-scroll-nightly ${name} ${key}: ${JSON.stringify(value)}`);
      await page.close();
      await pane!.close();

      // The run went where the repros are: older pages landed while the wheel moved up.
      expect(pages).toBeGreaterThan(0);
      expect(anchors.compared).toBe(anchors.frames);
      // Scroll-up history loading: nothing jumps, blanks, fades in or pulls the reader back.
      expect(anchors.cancelledWheels).toBe(0);
      expect(anchors.missingAnchors).toBe(0);
      expect(anchors.maxDrift).toBeLessThanOrEqual(1);
      expect(anchors.blankFrames).toBe(0);
      expect(anchors.blankBandFrames).toBe(0);
      expect(anchors.overlapFrames).toBe(0);
      expect(seen.fadedFrames).toBe(0);
      expect(seen.animatingFrames).toBe(0);
      expect(seen.thumbDown).toBe(0);
      // Jump to latest: shows once and holds still.
      expect(seen.jumpShown).toBe(true);
      expect(seen.jumpShownAtEnd).toBe(true);
      expect(seen.jumpFlips).toBe(0);
      expect(seen.jumpMoves).toBe(0);
      expect(seen.jumpDips).toBe(0);
      // Session Info: steady.
      expect(seen.infoOnPage).toBe(true);
      expect(seen.infoMoves).toBe(0);
      expect(seen.infoFaded).toBe(0);
      expect(watched.infoReplaced).toBe(false);
      expect(watched.infoChanges).toEqual([]);
    },
  );
});
