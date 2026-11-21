// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// Scrolled up, rows arrive; back down at the end, the room under the last row is never cut while
// the reader is looking at it (Leo, 2026-11-20: "so I've scrolled up and you guys have added two
// calls or messages ... there's like space at the bottom or something and it gets pushed and there's
// space for the composer as well maybe. And so I scroll down and there's like an extra bit of scroll
// that I maybe need to do, maybe not. And then like we cut it out. We cut out the extra space. And
// so that is the jump.").
//
// The reader parks 1200 px up a running turn, the turn's calls finish and its reply comes in (and,
// with a queue, the queued prompts run and the queue card leaves the bottom stack), then the reader
// wheels back down to the end in 40 px steps and on past it. At each step the rows in view move
// up by what the wheel scrolled and no more nor less; then, at rest at the end, they hold still.
// Any other move is the transcript moving content under the viewport ("px moved"), which is 0.
//
// One chat of 40 finished turns and a running one (support/papercutChat.ts) through the pane's dev
// entry and a stand-in acpmux. Real Chromium and WebKit (the app's engine) with real wheel events;
// every read is of a painted frame (support/paintedFrames.ts). CI fails the file when it cannot
// launch them (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-scrolled-up-bottom-trim.test.ts
import { deflateSync } from "node:zlib";
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { MAIN_DOCK } from "../src/agent-session/acpmux/composerSelectors";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-scrolled-up-bottom-trim.test.ts", async () => {
  setDefaultTimeout(600_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-scrolled-up-bottom-trim: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("scrolled up, bottom trim", () => test("browsers", () => {}));
    return;
  }
  const browsers: Browser[] = [];
  afterAll(async () => {
    for (const browser of browsers) await browser.close();
  });

  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const call = (id: string, command: string): PapercutStep => [
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
  ];
  const done = (id: string): PapercutStep => [
    "in",
    "tool_call_update",
    update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
  ];
  const say = (text: string): PapercutStep => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
  ];
  /// The running turn's calls finish, one more runs, and the reply comes in.
  const runningTurnEnds: PapercutStep[] = [
    done("r1"),
    done("r2"),
    say("Both checks pass. One more for the parser."),
    call("r3", "bun test parser"),
    done("r3"),
    say("All three are green: the parser, its tests and the merged head."),
    ["mux", "turn_result", { status: "completed" }],
  ];
  /// A queued prompt runs: the card leaves the queue, its prompt and the reply come in.
  const queuedRuns = (promptId: string, text: string, n: number): PapercutStep[] => [
    ["mux", "dequeued", { promptId }],
    ["mux", "user_message", { text, promptId, turnId: `turn-${promptId}` }],
    ["mux", "turn_started", {}],
    call(`${promptId}-c`, `bun test queued-${n}`),
    done(`${promptId}-c`),
    say(`Queued answer ${n}: that one is green too, and nothing else changed.`),
    ["mux", "turn_result", { status: "completed" }],
  ];
  const queue = [
    { promptId: "q-1", prompt: "The first queued prompt, about the parser and its tests" },
    { promptId: "q-2", prompt: "The second queued prompt, about the docs" },
  ];
  const cases: {
    name: string;
    session?: Record<string, unknown>;
    arrive: PapercutStep[];
    /// Attach only the newest records and hold every older page's reply until the reader is back at the
    /// end with the room kept: the page then lands above them, which must not eat the room nor move them.
    olderPageAtEnd?: true;
  }[] = [
    { name: "calls and a reply", arrive: runningTurnEnds },
    {
      name: "calls, a reply and the queue's prompts",
      session: { steering: true, queuePaused: false, queued: queue.length, queue },
      arrive: [
        ...runningTurnEnds,
        ...queuedRuns("q-1", queue[0]!.prompt, 1),
        ...queuedRuns("q-2", queue[1]!.prompt, 2),
      ],
    },
    { name: "calls and a reply, then an older page lands", arrive: runningTurnEnds, olderPageAtEnd: true },
  ];

  /// Waits until the transcript and the stack hold still over 12 painted frames, and no finite
  /// animation runs.
  const settle = (page: Page) =>
    page.evaluate(
      ({ MAIN_DOCK }) =>
        new Promise<void>((resolve) => {
          let last = "";
          let still = 0;
          let frames = 0;
          window.cmuxAfterPaint(() => {
            frames++;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const dock = document.querySelector<HTMLElement>(MAIN_DOCK);
            const now = [scroller.scrollTop, scroller.scrollHeight, dock?.getBoundingClientRect().top].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            still = now === last && !running ? still + 1 : 0;
            last = now;
            if (still < 12 && frames < 600) return true;
            resolve();
            return false;
          });
        }),
      { MAIN_DOCK },
    );
  type View = { fromEnd: number; room: number; tops: [string, number][] };
  /// After `frames` painted frames: the scroller's distance from its end, the room between the last
  /// row and the stack, and the screen top of each row in view.
  const view = (page: Page, frames = 1) =>
    page.evaluate(
      ({ frames, TRANSCRIPT_ROW, MAIN_DOCK }) =>
        new Promise<View>((resolve) => {
          let painted = 0;
          window.cmuxAfterPaint(() => {
            if (++painted < frames) return true;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const box = scroller.getBoundingClientRect();
            const rows = [...scroller.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)];
            const dock = document.querySelector<HTMLElement>(MAIN_DOCK)!.getBoundingClientRect();
            const last = Math.max(...rows.map((row) => row.getBoundingClientRect().bottom));
            const tops: [string, number][] = [];
            for (const row of rows) {
              const rect = row.getBoundingClientRect();
              if (rect.bottom > box.top && rect.top < dock.top) tops.push([row.dataset.rowId!, rect.top]);
            }
            resolve({
              fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
              room: dock.top - last,
              tops,
            });
            return false;
          });
        }),
      { frames, TRANSCRIPT_ROW, MAIN_DOCK },
    );
  /// How far the rows in view both times moved down from `before` to `after` (the median row).
  const movedDown = (before: View, after: View) => {
    const was = new Map(before.tops);
    const moves = after.tops.filter(([id]) => was.has(id)).map(([id, top]) => top - was.get(id)!);
    moves.sort((a, b) => a - b);
    return moves.length ? moves[Math.floor(moves.length / 2)]! : 0;
  };
  const STEP = 40;
  const wheel = async (page: Page, deltaY: number) => {
    await page.mouse.move(450, 150);
    await page.mouse.wheel(0, deltaY);
  };

  /// Records, every painted frame from now until `stop()`, the largest downward move of the rows in view
  /// since the frame before (the median row), as a frame where the whole transcript drops back would show.
  const watchDrops = (page: Page) =>
    page.evaluate(
      ({ TRANSCRIPT_ROW }) => {
        const w = window as unknown as { __drops: number[]; __dropStop: boolean };
        w.__drops = [];
        w.__dropStop = false;
        let was = new Map<string, number>();
        window.cmuxAfterPaint(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const now = new Map<string, number>();
          for (const row of scroller.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW))
            now.set(row.dataset.rowId!, row.getBoundingClientRect().top);
          const moves = [...now].filter(([id]) => was.has(id)).map(([id, top]) => top - was.get(id)!);
          moves.sort((a, b) => a - b);
          w.__drops.push(moves.length ? moves[Math.floor(moves.length / 2)]! : 0);
          was = now;
          return !w.__dropStop;
        });
      },
      { TRANSCRIPT_ROW },
    );
  const drops = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __drops: number[]; __dropStop: boolean };
      w.__dropStop = true;
      return w.__drops;
    });

  // Leo, 2026-11-18, with a recording: "did we fix this scroll bounce at the bottom yet?" At the end of a
  // running chat, as its calls came in and its clocks ticked, the whole transcript dropped back ~125 px and
  // glided up again, about once a second. A reader following at the end sees rows only rise or hold.
  for (const [engine, type] of engines) {
    test(`${engine}: following at the end of a running chat, rows never drop back`, async () => {
      const browser = await type.launch({ headless: true });
      browsers.push(browser);
      const pane = await papercutPane(() => browser, { turns: 40, running: true });
      try {
        const page = await pane.open({ width: 900, height: 700 });
        await settle(page);
        expect((await view(page)).fromEnd).toBeLessThanOrEqual(1);
        await watchDrops(page);
        const arrive: PapercutStep[] = [
          done("r1"),
          say("Checking why the worker cloned the repository as a path."),
          call("b1", "cmux-ci submit --kind cmux --label macos-26 --request-key kit-macos-build"),
          done("r2"),
          say("The build job failed on its checkout step."),
          call("b2", "bun test parser"),
        ];
        for (const [dir, kind, msg] of arrive) {
          pane.record(kind, msg, dir);
          // fixed-wait: calls arrive this far apart in a live turn, each across a clock tick.
          await page.waitForTimeout(700);
          // The reader's wheel at the end, on past it, as Leo's was.
          for (let i = 0; i < 3; i++) await wheel(page, STEP);
        }
        // fixed-wait: the timing is the behaviour under test: three clock ticks at rest at the end.
        await page.waitForTimeout(3200);
        await settle(page);
        const all = await drops(page);
        const dropped = all.map((px, frame) => [frame, Math.round(px * 10) / 10]).filter(([, px]) => px! > 1);
        const end = await view(page);
        console.log(
          `bottom-bounce ${engine}: ${all.length} frames, drops ${JSON.stringify(dropped)}, from end at rest ${end.fromEnd.toFixed(1)}`,
        );
        expect({ engine, dropped, atEnd: end.fromEnd <= 1 }).toEqual({ engine, dropped: [], atEnd: true });
        await page.close();
      } finally {
        await pane.close();
      }
    });
  }

  /// A solid PNG of `width` x `height`, base64: a sent image's bytes as `_acpmux/attachment` answers them.
  const solidPng = (width: number, height: number, rgb: [number, number, number]) => {
    const crcTable = Array.from({ length: 256 }, (_, n) => {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      return c >>> 0;
    });
    const crc = (bytes: Buffer) => {
      let c = 0xffffffff;
      for (const byte of bytes) c = crcTable[(c ^ byte) & 0xff]! ^ (c >>> 8);
      return (c ^ 0xffffffff) >>> 0;
    };
    const chunk = (kind: string, data: Buffer) => {
      const length = Buffer.alloc(4);
      length.writeUInt32BE(data.length);
      const body = Buffer.concat([Buffer.from(kind, "ascii"), data]);
      const sum = Buffer.alloc(4);
      sum.writeUInt32BE(crc(body));
      return Buffer.concat([length, body, sum]);
    };
    const header = Buffer.alloc(13);
    header.writeUInt32BE(width, 0);
    header.writeUInt32BE(height, 4);
    header[8] = 8;
    header[9] = 2;
    const row = Buffer.alloc(1 + width * 3);
    for (let x = 0; x < width; x++) row.set(rgb, 1 + x * 3);
    const raw = Buffer.concat(Array.from({ length: height }, () => row));
    return Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      chunk("IHDR", header),
      chunk("IDAT", deflateSync(raw)),
      chunk("IEND", Buffer.alloc(0)),
    ]).toString("base64");
  };

  // The same, with what Leo's chat had on screen: the newest prompt sent a screen recording (its tile:
  // poster, play glyph, length) and a wide short screenshot above its two lines of text, as acpmux
  // records a prompt the composer placed (hub/prompt_images.rs `inline_parts`: the video's link, its
  // frames note and first frame, the screenshot, then the text), and its running turn reads, thinks
  // and runs a command. With `waiting`, acpmux is slow to answer (a `_acpmux/view` held), so the dock
  // says "Waiting for the agent service (m:ss)" with Restart agent service and counts each second.
  const VIDEO = "Recording 2026-11-18 at 10.02.11.mov";
  const POSTER_ID = "a".repeat(64);
  const SHOT_ID = "b".repeat(64);
  const mediaPrompt = (): PapercutStep => {
    const note = `Frames from the video ${VIDEO} (0:07, 1920×1080), in order, at: 0:00.0.`;
    const text = "did we fix this scroll bounce at the bottom yet?\nit drops and comes back every second";
    return [
      "mux",
      "user_message",
      {
        text: `${note}\n${VIDEO} frames\n${text}`,
        promptId: "p-media",
        turnId: "turn-media",
        images: [
          { id: POSTER_ID, mimeType: "image/png", name: `${VIDEO} frame at 0:00.0`, width: 640, height: 360 },
          {
            id: SHOT_ID,
            mimeType: "image/png",
            name: "Screenshot 2026-11-18 at 10.01.40.png",
            width: 2400,
            height: 420,
          },
        ],
        inlineParts: [
          {
            kind: "file",
            name: VIDEO,
            uri: `file:///Users/you/Desktop/${encodeURIComponent(VIDEO)}`,
            mimeType: "video/quicktime",
            placed: true,
          },
          { kind: "text", text: note },
          { kind: "text", text: `${VIDEO} frames` },
          {
            kind: "image",
            id: POSTER_ID,
            mimeType: "image/png",
            name: `${VIDEO} frame at 0:00.0`,
            width: 640,
            height: 360,
          },
          {
            kind: "image",
            id: SHOT_ID,
            mimeType: "image/png",
            name: "Screenshot 2026-11-18 at 10.01.40.png",
            width: 2400,
            height: 420,
            placed: true,
          },
          { kind: "text", text },
        ],
      },
    ];
  };
  const thought = (text: string): PapercutStep => [
    "in",
    "agent_thought_chunk",
    update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }),
  ];
  const read = (id: string, title: string): PapercutStep => [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title,
      kind: "read",
      status: "in_progress",
      rawInput: { file_path: "/home/dev/cmux/build-fleet/recipes/cmux-build.sh" },
    }),
  ];
  for (const [engine, type] of engines) {
    for (const waiting of [false, true]) {
      const name = `${engine}: following at the end of a running chat whose prompt sent a video and an image${waiting ? ", acpmux slow" : ""}, rows never drop back`;
      test(name, async () => {
        const browser = await type.launch({ headless: true });
        browsers.push(browser);
        const pane = await papercutPane(() => browser, {
          turns: 40,
          running: false,
          extra: [
            mediaPrompt(),
            ["mux", "turn_started", {}],
            read("m1", "Read why the kit build failed"),
            done("m1"),
            thought("The checkout step cloned the repository as a path, not a URL."),
            call("m2", "cmux-ci submit --kind cmux --label macos-26 --request-key kit-macos-build"),
          ],
          session: {
            status: "running",
            turn: { turnId: "turn-media", promptId: "p-media", startedAt: Date.now() - 483_000, prompt: "did we fix" },
          },
          attachments: {
            [POSTER_ID]: { mimeType: "image/png", data: solidPng(640, 360, [40, 90, 160]) },
            [SHOT_ID]: { mimeType: "image/png", data: solidPng(2400, 420, [220, 220, 210]) },
          },
        });
        try {
          const page = await pane.open({ width: 900, height: 700 });
          // The poster and the screenshot drawn, read from acpmux by their ids.
          await page.waitForFunction(
            () =>
              [...document.querySelectorAll<HTMLImageElement>(".cv-user img.cv-user__image")].filter(
                (image) => image.complete && image.naturalWidth > 0,
              ).length >= 2,
            undefined,
            { timeout: 60_000 },
          );
          await settle(page);
          if (waiting) {
            // acpmux holds the page's next view (a busy daemon): the reader steps away and back.
            pane.stall(["_acpmux/view"]);
            await page.evaluate(() => {
              const set = (state: string) => {
                Object.defineProperty(document, "visibilityState", { configurable: true, get: () => state });
                Object.defineProperty(document, "hidden", { configurable: true, get: () => state === "hidden" });
                document.dispatchEvent(new Event("visibilitychange"));
              };
              set("hidden");
              set("visible");
            });
            const shown = await page
              .locator("[data-host-waiting]")
              .first()
              .waitFor({ timeout: 60_000 })
              .then(
                () => true,
                () => false,
              );
            console.log(`bottom-bounce ${engine}: waiting line shown ${shown}`);
            await settle(page);
          }
          expect((await view(page)).fromEnd).toBeLessThanOrEqual(1);
          // Per painted frame, the media's boxes: a tile or image that collapses and comes back shows here.
          await page.evaluate(() => {
            const w = window as unknown as { __media: string[]; __dropStop: boolean };
            w.__media = [];
            let last = "";
            window.cmuxAfterPaint(() => {
              const now = [
                ...document.querySelectorAll<HTMLElement>(
                  ".cv-user__video, .cv-user img.cv-user__image, .cv-user .cv-user__image-placeholder",
                ),
              ]
                .map((el) => `${el.className.split(" ")[0]}:${Math.round(el.getBoundingClientRect().height)}`)
                .join(",");
              if (now !== last) w.__media.push(`${Math.round(performance.now())} ${now}`);
              last = now;
              return !w.__dropStop;
            });
          });
          await watchDrops(page);
          const arrive: PapercutStep[] = [
            done("m2"),
            thought("The build job failed on its checkout step."),
            call("m3", "cmux-ci submit --kind cmux --label macos-26 --request-key kit-macos-build-2"),
            read("m4", "Read why the second build failed"),
            done("m4"),
            call("m5", "bun test parser"),
          ];
          for (const [dir, kind, msg] of arrive) {
            pane.record(kind, msg, dir);
            // fixed-wait: calls arrive this far apart in a live turn, each across a clock tick.
            await page.waitForTimeout(700);
            for (let i = 0; i < 3; i++) await wheel(page, STEP);
          }
          // fixed-wait: the timing is the behaviour under test: clock ticks at rest at the end.
          await page.waitForTimeout(3200);
          for (let i = 0; i < 6; i++) await wheel(page, STEP);
          // fixed-wait: more ticks after the wheel.
          await page.waitForTimeout(2200);
          await settle(page);
          const all = await drops(page);
          const media = await page.evaluate(() => (window as unknown as { __media: string[] }).__media);
          const dropped = all.map((px, frame) => [frame, Math.round(px * 10) / 10]).filter(([, px]) => px! > 1);
          const end = await view(page);
          console.log(
            `bottom-bounce media${waiting ? "+waiting" : ""} ${engine}: ${all.length} frames, drops ${JSON.stringify(dropped)}, from end at rest ${end.fromEnd.toFixed(1)}`,
          );
          console.log(`bottom-bounce media boxes ${engine}: ${JSON.stringify(media)}`);
          expect({ engine, dropped, atEnd: end.fromEnd <= 1 }).toEqual({ engine, dropped: [], atEnd: true });
          await page.close();
        } finally {
          await pane.close();
        }
      });
    }
  }

  for (const [engine, type] of engines) {
    for (const each of cases) {
      test(`${engine}: scrolled up, ${each.name} arrive; back at the end, nothing moves under the view`, async () => {
        const browser = await type.launch({ headless: true });
        browsers.push(browser);
        const pane = await papercutPane(() => browser, {
          turns: 40,
          running: true,
          session: each.session,
          ...(each.olderPageAtEnd ? { attachPage: 80 } : {}),
        });
        if (each.olderPageAtEnd) pane.stall(["_acpmux/events"]);
        try {
          const page = await pane.open({ width: 900, height: 700 });
          await settle(page);
          const rest = await view(page);
          expect(rest.fromEnd).toBeLessThanOrEqual(1);
          for (let moved = 0; moved < 1200; moved += STEP) await wheel(page, -STEP);
          await settle(page);
          for (const [dir, kind, msg] of each.arrive) pane.record(kind, msg, dir);
          await settle(page);
          // fixed-wait: past the page's own arrival holds (a sent prompt's room is held FLOOR_HOLD_MS on its
          // timer), so what the reader comes back down to is what those timers left, not what they will cut.
          await page.waitForTimeout(500);
          await settle(page);
          const parked = await view(page);
          // Still where the reader parked: arrivals never pull a reader who scrolled up down.
          expect(parked.fromEnd).toBeGreaterThan(600);
          /// Each step: [what the wheel could scroll, how far the rows in view moved down beyond it].
          const steps: [number, number][] = [];
          let before = parked;
          let atEnd: View | undefined;
          for (let step = 0; step < 120; step++) {
            await wheel(page, STEP);
            const after = await view(page, 3);
            const asked = Math.min(STEP, Math.max(0, before.fromEnd));
            steps.push([Math.round(asked * 10) / 10, Math.round((movedDown(before, after) + asked) * 10) / 10]);
            atEnd ??= after.fromEnd <= 0.5 ? after : undefined;
            before = after;
            // Three more steps on past the end, as a reader's wheel does.
            if (atEnd && steps.length >= 3 && steps.slice(-3).every(([asked]) => asked === 0)) break;
          }
          expect(atEnd).toBeDefined();
          if (each.olderPageAtEnd) {
            // The reader went up past the loaded top, so a page was asked; it lands now, at the end.
            expect(pane.history.requests.length).toBeGreaterThan(0);
            await settle(page);
            before = await view(page);
            pane.stall([]);
          }
          await settle(page);
          // fixed-wait: the timing is the behaviour under test: the room kept at the end must still be there
          // after the page's FLOOR_HOLD_MS (1000 ms) timer, which is when a cut would come.
          await page.waitForTimeout(1500);
          await settle(page);
          const later = await view(page);
          const idle = movedDown(before, later);
          const moved = steps.filter(([, extra]) => Math.abs(extra) > 1);
          const total = moved.reduce((sum, [, extra]) => sum + Math.abs(extra), 0) + Math.abs(idle);
          console.log(
            `bottom-trim ${engine} "${each.name}": px moved under the view ${total.toFixed(1)} ` +
              `(steps ${JSON.stringify(moved)}, at rest ${idle.toFixed(1)}); room under the last row: ` +
              `at the latest row before ${rest.room.toFixed(1)}, on reaching the end ${atEnd!.room.toFixed(1)}, ` +
              `at rest ${later.room.toFixed(1)}; ${steps.length} steps`,
          );
          expect({ engine, case: each.name, moved, idle: Math.abs(idle) > 1 ? idle : 0 }).toEqual({
            engine,
            case: each.name,
            moved: [],
            idle: 0,
          });
          await page.close();
        } finally {
          await pane.close();
        }
      });
    }
  }
});
