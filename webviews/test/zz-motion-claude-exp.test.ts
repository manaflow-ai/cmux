// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The send motion's contract (support/motionContract.ts), in the agent pane as the app draws it.
// Leo, 2026-11-11: "I send a message and it doesn't scroll down for me automatically, and then ...
// there's the thinking, or maybe there's a tooltip, and I scroll down to the bottom. I have to scroll
// down again ... when the new messages come in, like the animation is just way too slow for when the
// rest of the transcript moves up and your message comes in ... It's not fast enough and it's not
// together enough. Any and all animations can be good if only they meet those prerequisites ...
// There should be, like, mathematical ways to determine what is wrong with ours." And on the queue:
// "Like you sending a message while I have things queued up, like that sort of slow growth is
// just... it gives me the heebie-jeebies to look at."
//
// Every painted frame of each transition is recorded (every row in view, the composer's card, the
// queue and its rows, every animation and the longest main-thread block) and held to the contract:
// (a) at rest within 150 ms of its first moving frame, (b) frames at 120 Hz (Chromium draws on a
// 120 Hz BeginFrame clock, support/frames120.ts; headless WebKit has no 120 Hz clock, so there the
// bound is the main-thread block: none over two slots), (c) everything that moves starts and rests
// in the same frame, (d) nothing moves twice, reverses, or grows over more than two frames.
//
// Transitions: a send from the latest row; a send while scrolled up, then the turn's thinking, a tool
// call and its first text growing under it (the view stays at the bottom after each: a layout change
// below never counts as scrolling up); with prompts queued, an agent message arriving and growing; and
// a send while prompts are queued.
//
// The pane's production build (papercutChat.ts), a stand-in acpmux. Real Chromium and WebKit. The
// report of every transition prints as one JSON line (`motion-contract`) for the PR's table.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { PluginOption } from "vite";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { FramesUnsupported, open120Hz, type Frames120 } from "./support/frames120";
import {
  analyzeMotion,
  contractFailures,
  installMotionRecorder,
  type MotionContractReport,
  type MotionRecording,
} from "./support/motionContract";
import { installPaintedFrames } from "./support/paintedFrames";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("zz-motion-claude-exp.test.ts", async () => {
  setDefaultTimeout(400_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-send-motion-contract: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("send motion contract", () => test("no engine", () => {}));
    return;
  }
  /// Chromium on the 120 Hz BeginFrame clock needs chrome-headless-shell (scripts/ci/ensure-system-chrome.sh).
  let chromium120 = true;
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    chromium120 = false;
    console.warn("agent-pane-send-motion-contract: Chromium draws at its own 60 Hz here; cadence is not gated");
  }

  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const thought = (text: string) => update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });
  const QUEUE = ["one", "two", "three"].map((word, index) => ({
    promptId: `q-${index + 1}`,
    prompt: `The ${word} queued prompt, about the parser and its tests`,
  }));

  /// The frames' own clock (browser/frameClock.ts) inlined ahead of the pane's modules: with
  /// `?clock=frames` the page's timers, `performance.now` and animations see a 120 Hz display that never
  /// drops a frame, so what each frame draws follows from the frames before it, not from how loaded the
  /// runner is (send-stream-motion.test.ts does the same). The motion checks (a), (c) and (d) read
  /// those frames; the cadence (b) reads the runner's own draw times.
  const clockSource = new Bun.Transpiler({ loader: "ts" })
    .transformSync(await Bun.file(path.join(import.meta.dir, "browser/frameClock.ts")).text())
    .replace(/^export /gm, "");
  const frameClock: PluginOption = {
    name: "motion-contract-frame-clock",
    transformIndexHtml: (html) =>
      html.replace("<head>", `<head><script>localStorage.setItem("cmux.composer.look", "claude");${clockSource}</script>`),
  };
  const browsers = new Map<string, Browser>();
  let idle: Awaited<ReturnType<typeof papercutPane>> | undefined;
  let queued: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const first = () => browsers.values().next().value!;
    idle = await papercutPane(first, { turns: 40, running: false, production: {}, vitePlugins: [frameClock] });
    queued = await papercutPane(first, {
      turns: 40,
      running: true,
      production: {},
      vitePlugins: [frameClock],
      session: { steering: true, queuePaused: false, queued: QUEUE.length, queue: QUEUE },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await idle?.close();
    await queued?.close();
  });

  /// The idle chat's newest text: each test leaves its turn in the chat's log.
  let lastIdle = "Answer 40:";
  type Opened = { page: Page; frames?: Frames120; close(): Promise<void> };
  /// The chat at its latest row, at rest: Chromium on the 120 Hz clock, WebKit on its own.
  async function open(name: string, pane: NonNullable<typeof idle>, ready: string): Promise<Opened> {
    const t0 = Date.now();
    const viewport = { width: 980, height: 700 };
    let page: Page;
    let frames: Frames120 | undefined;
    if (name === "chromium" && chromium120) {
      frames = await open120Hz(pane.address().replace("/#", "/?clock=frames#"), { viewport, clock: "frames" });
      current = frames;
      page = frames.page;
    } else page = await browsers.get(name)!.newPage({ viewport });
    page.on("console", (m) => {
      if (m.text().startsWith("DIAG")) console.log(`${m.text()} wall ${Date.now() - t0}`);
    });
    await installPaintedFrames(page);
    await installMotionRecorder(page);
    if (!frames) await page.goto(pane.address());
    await watched(page, "open ready", page.getByText(ready, { exact: false }).first().waitFor({ timeout: 120_000 }));
    await watched(page, "open settle", settle(page));
    return {
      page,
      frames,
      close: async () => {
        if (frames) await frames.close();
        else await page.close();
      },
    };
  }

  /// Until the transcript, the stack and every finite animation hold still over 12 painted frames.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let last = "";
          let still = 0;
          let frames = 0;
          window.cmuxAfterPaint(() => {
            frames += 1;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            const thread = document.querySelector<HTMLElement>(".acpmux-thread");
            const dock = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock");
            const now = [
              scroller?.scrollTop,
              scroller?.scrollHeight,
              dock?.getBoundingClientRect().top,
              thread?.getBoundingClientRect().top,
            ].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" &&
                  Number.isFinite(animation.effect?.getComputedTiming().endTime ?? Number.POSITIVE_INFINITY),
              );
            still = now === last && !running ? still + 1 : 0;
            if (frames % 60 === 0 || frames >= 900)
              console.log(
                `DIAG settle frame ${frames} at ${Math.round(performance.now())} still ${still} now ${now} last ${last} running ${document
                  .getAnimations()
                  .filter(
                    (a) =>
                      a.playState === "running" &&
                      Number.isFinite(a.effect?.getComputedTiming().endTime ?? Number.POSITIVE_INFINITY),
                  )
                  .map((a) => `${(a as CSSAnimation).animationName ?? a.constructor.name}@${((a.effect as KeyframeEffect | null)?.target as Element | null)?.className}`)
                  .join(",")}`,
              );
            last = now;
            if (still < 12 && frames < 900) return true;
            resolve();
            return false;
          });
        }),
    );
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
    });
  const mark = (page: Page, name: string) => page.evaluate((name) => window.__motion.mark(name), name);
  const composer = (page: Page) => page.locator(".acpmux-composer-box [contenteditable=true]").first();

  /// Types `text` and sends it with Enter, marking the frame; returns the prompt id the page sent.
  let current: Frames120 | undefined;
  async function watched<T>(page: Page, what: string, work: Promise<T>): Promise<T> {
    const dog = setInterval(async () => {
      const cdp = current ? await page.context().newCDPSession(page).catch(() => undefined) : undefined;
      const state = cdp
        ? await Promise.race([
            cdp
              .send("Runtime.evaluate", { expression: "JSON.stringify(globalThis.__frameClockDebug?.())", returnByValue: true } as never)
              .then((r) => (r as { result: { value: string } }).result.value)
              .catch((e) => `err ${e}`),
            new Promise((r) => setTimeout(() => r("page did not answer in 5 s"), 5000)),
          ])
        : "no cdp";
      console.log(`DIAG stuck in ${what}: pump ${JSON.stringify(current?.debug())} page ${state}`);
    }, 15_000);
    try {
      return await work;
    } finally {
      clearInterval(dog);
    }
  }
  async function send(page: Page, pane: NonNullable<typeof idle>, text: string) {
    await watched(page, "click", composer(page).click());
    await watched(page, "type", page.keyboard.type(text));
    await watched(page, "settle after typing", settle(page));
    const before = pane.prompts.length;
    const asked = pane.sent("session/prompt", pane.methods.filter((method) => method === "session/prompt").length);
    await mark(page, "send");
    await page.keyboard.press("Enter");
    await asked;
    return pane.prompts[before]?._meta?.acpmux?.promptId as string;
  }

  /// Splits the recording at its marks: each transition runs from the frame before its mark to the
  /// next mark.
  function transitions(recording: MotionRecording) {
    const at: { name: string; index: number }[] = [];
    recording.frames.forEach((frame, index) => frame.marks.forEach((name) => at.push({ name, index })));
    return at.map((entry, i) => ({
      name: entry.name,
      from: Math.max(0, entry.index - 1),
      to: at[i + 1]?.index ?? recording.frames.length,
    }));
  }

  /// Every recording, for the gallery's frame strips and a re-analysis (CMUX_MOTION_CONTRACT_OUT).
  const recordings: { engine: string; scenario: string; recording: MotionRecording }[] = [];
  const reports: { engine: string; scenario: string; transition: string; report: MotionContractReport }[] = [];
  /// The checks each engine gates: Chromium draws on the frames' own clock, so its speed (a),
  /// togetherness (c) and once (d) are exact and repeat run to run. Headless WebKit draws at its own
  /// pace on a loaded runner (17-190 ms a frame): a row's move split over those frames reads as two
  /// moves one run and one the next, so WebKit is reported (motion-contract lines) and gates nothing.
  /// The cadence (b) is the runner's draw time, not a Mac's: reported, gated by no runner.
  const GATED: Record<string, string[]> = { chromium: chromium120 ? ["a", "c", "d"] : [], webkit: [] };
  /// The ratchet (motion-contract-baseline.json): each transition's checks known to fail today. A
  /// check failing outside it fails the test; one in it that passes now is printed so it can come out.
  /// New motion meets the whole contract from its first run.
  const baseline = (await Bun.file(path.join(import.meta.dir, "motion-contract-baseline.json")).json()) as Record<
    string,
    string[]
  >;
  /// The runner's own draw times over a scenario (frames120: ask to drawn, and slots no frame began in).
  function logPacing(engine: string, pacing: { frameMs: number[]; dropped: number } | undefined) {
    if (!pacing?.frameMs.length) return;
    const sorted = [...pacing.frameMs].sort((a, b) => a - b);
    const p95 = sorted[Math.min(sorted.length - 1, Math.floor(0.95 * sorted.length))]!;
    console.log(
      `motion-contract pacing ${JSON.stringify({ engine, frames: sorted.length, p95: Math.round(p95 * 100) / 100, max: Math.round(sorted.at(-1)! * 100) / 100, over16: sorted.filter((ms) => ms > 1000 / 60).length, dropped: pacing.dropped })}`,
    );
  }
  /// Holds every transition of `recording` to the contract; returns the failures outside the ratchet.
  function judge(engine: string, scenario: string, recording: MotionRecording) {
    recordings.push({ engine, scenario, recording });
    const failures: Record<string, string[]> = {};
    for (const transition of transitions(recording)) {
      const report = analyzeMotion(recording, { from: transition.from, to: transition.to });
      reports.push({ engine, scenario, transition: transition.name, report });
      const { elements, ...summary } = report;
      const failed = contractFailures(report);
      const key = `${engine} ${scenario} ${transition.name}`;
      const letters = [...new Set(failed.map((line) => line[1]!))];
      console.log(
        `motion-contract ${JSON.stringify({ key, failing: letters, ...summary, elements: elements.slice(0, 12) })}`,
      );
      const allowed = baseline[key] ?? [];
      const gated = failed.filter((line) => GATED[engine]!.includes(line[1]!) && !allowed.includes(line[1]!));
      const fixed = allowed.filter((letter) => !letters.includes(letter));
      if (fixed.length) console.log(`motion-contract ratchet: ${key} now passes (${fixed.join(", ")}): take it out`);
      if (gated.length) failures[transition.name] = gated;
    }
    return failures;
  }

  for (const [name] of engines) {
    describe(name, () => {
      test("a send from the latest row: the prompt, the shift and the composer move as one, fast, once", async () => {
        const opened = await open(name, idle!, lastIdle);
        const { page } = opened;
        try {
          await page.evaluate(() => window.__motion.start());
          opened.frames?.start();
          const promptId = await send(page, idle!, `Latest-row send in ${name}`);
          lastIdle = "The relay falls over when the retry fires twice.";
          idle!.record("user_message", { text: `Latest-row send in ${name}`, promptId, turnId: `turn-${promptId}` });
          idle!.record("turn_started", {});
          await settle(page);
          await mark(page, "thinking");
          idle!.record("agent_thought_chunk", thought("Reading the relay and its retry path."), "in");
          await settle(page);
          await mark(page, "message");
          idle!.record("agent_message_chunk", chunk("The relay falls over when the retry fires twice."), "in");
          await settle(page);
          await mark(page, "end");
          idle!.record("turn_result", { status: "completed" });
          await settle(page);
          const recording = await page.evaluate(() => window.__motion.stop());
          logPacing(name, await opened.frames?.stop());
          const failures = judge(name, "latest", recording);
          expect(await fromEnd(page)).toBeLessThanOrEqual(1);
          expect(failures).toEqual({});
        } finally {
          await opened.close();
        }
      });

      test("a send while scrolled up lands at the bottom and stays there as the turn's rows grow under it", async () => {
        const opened = await open(name, idle!, lastIdle);
        const { page } = opened;
        try {
          await page.mouse.move(490, 200);
          for (let moved = 0; moved < 1200; moved += 40) await page.mouse.wheel(0, -40);
          await settle(page);
          expect(await fromEnd(page)).toBeGreaterThan(600);
          await page.evaluate(() => window.__motion.start());
          opened.frames?.start();
          const promptId = await send(page, idle!, `Scrolled-up send in ${name}`);
          idle!.record("user_message", { text: `Scrolled-up send in ${name}`, promptId, turnId: `turn-${promptId}` });
          idle!.record("turn_started", {});
          await settle(page);
          const ends: Record<string, number> = { send: await fromEnd(page) };
          // The turn grows under the view in three steps: its thinking, a tool call, its first text.
          const steps: [string, () => void][] = [
            ["thinking", () => idle!.record("agent_thought_chunk", thought("Reading the relay. ".repeat(6)), "in")],
            [
              "tool",
              () =>
                idle!.record(
                  "tool_call",
                  update({
                    sessionUpdate: "tool_call",
                    toolCallId: `grep-${name}`,
                    title: "Grep reconnect",
                    kind: "search",
                    status: "in_progress",
                  }),
                  "in",
                ),
            ],
            [
              "text",
              () =>
                idle!.record(
                  "agent_message_chunk",
                  chunk(
                    "The relay falls over when the retry fires twice.\n\nIt holds the socket open.\n\n- one\n- two",
                  ),
                  "in",
                ),
            ],
          ];
          for (const [step, play] of steps) {
            await mark(page, step);
            play();
            await settle(page);
            ends[step] = await fromEnd(page);
          }
          await mark(page, "end");
          idle!.record("turn_result", { status: "completed" });
          await settle(page);
          ends.end = await fromEnd(page);
          const recording = await page.evaluate(() => window.__motion.stop());
          logPacing(name, await opened.frames?.stop());
          // The view is at the bottom after the send and after every step.
          expect(Object.fromEntries(Object.entries(ends).map(([step, px]) => [step, px <= 1 ? 0 : px]))).toEqual({
            send: 0,
            thinking: 0,
            tool: 0,
            text: 0,
            end: 0,
          });
          // The ride down is the reader's own Jump: its contract is the ride's speed and cadence, and
          // every row moves with the scroll (one motion).
          expect(judge(name, "scrolled-up", recording)).toEqual({});
        } finally {
          await opened.close();
        }
      });

      test("with prompts queued, an agent message arrives at its height, and the queue holds still", async () => {
        const opened = await open(name, queued!, "The one queued prompt");
        const { page } = opened;
        try {
          await page.evaluate(() => window.__motion.start());
          opened.frames?.start();
          await mark(page, "message");
          queued!.record("agent_message_chunk", chunk(`Both runs are green in ${name}. `), "in");
          await settle(page);
          await mark(page, "grows");
          queued!.record(
            "agent_message_chunk",
            chunk("The parser keeps its tests.\n\n- The queue runs next.\n- Then the docs."),
            "in",
          );
          await settle(page);
          const recording = await page.evaluate(() => window.__motion.stop());
          logPacing(name, await opened.frames?.stop());
          const failures = judge(name, "queued-arrival", recording);
          // The queue's rows never move while the transcript takes the message.
          const queueMoved = recording.frames.some((frame, index) => {
            const before = recording.frames[index - 1];
            if (!before) return false;
            return Object.entries(frame.els).some(
              ([key, el]) =>
                key.startsWith("queued:") && before.els[key] && Math.abs(el.top - before.els[key]!.top) > 0.5,
            );
          });
          expect({ queueMoved, failures }).toEqual({ queueMoved: false, failures: {} });
        } finally {
          await opened.close();
        }
      });

      test("a send while prompts are queued: its queued row is whole at once, nothing else shifts", async () => {
        const opened = await open(name, queued!, "The one queued prompt");
        const { page } = opened;
        try {
          await page.evaluate(() => window.__motion.start());
          opened.frames?.start();
          const text = `Queued send in ${name}`;
          const promptId = await send(page, queued!, text);
          queued!.record("queued", { promptId, text });
          await settle(page);
          const recording = await page.evaluate(() => window.__motion.stop());
          logPacing(name, await opened.frames?.stop());
          expect(judge(name, "queued-send", recording)).toEqual({});
        } finally {
          await opened.close();
        }
      });
    });
  }

  afterAll(async () => {
    if (process.env.CMUX_MOTION_CONTRACT_OUT)
      await Bun.write(process.env.CMUX_MOTION_CONTRACT_OUT, JSON.stringify({ reports, recordings }));
  });
});
