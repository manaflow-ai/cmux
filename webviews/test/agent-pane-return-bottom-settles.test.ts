// A reader who scrolls up while a turn streams, then wheels back to its latest row as the turn ends, sits exactly
// at the end of the scroller and stays there: the turn's last rows land at the end in the frame they come, inside
// the input hold the reader's wheel leaves.
//
// Following is deferred while the reader's input is held (userScroll.ts `isHeld`, one second after the last
// input), unless a move toward the latest row asked to follow through it (`followRequest`). A wheel down while
// already following asks; the wheel down whose scroll brought following back did not, so the rows the turn's end
// added under it were left below the view's foot until the hold ran out: the view sat 23 px short of the end about
// 300 ms after the return (#46511's run 44383856146), while following.
//
// The load goes in as the host's push does, through the client's transport socket, as
// agent-pane-older-paging-return-keeps-rows.test.ts does. The distance to the end is sampled every frame.
/// <reference types="bun" />
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-return-bottom-settles.test.ts", async () => {
  /// How soon after the return the view must sit at the end, and how long it must stay there.
  const SETTLE_MS = 500;
  const WATCH_MS = 1_500;
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a reader wheeling back to the latest row as the turn ends sits at the end and stays there", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 1000 } });
    await installPaintedFrames(page);
    // A notched wheel glides through the motion clock; the reader's scroll here is the browser's own.
    await page.emulateMedia({ reducedMotion: "reduce" });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadSeed(500, { light: true }),
    )) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });

    const started = (await page.evaluate(
      ({ session, selectors }) => {
        type Socket = { readyState: number; onmessage: ((message: { data: string }) => void) | null };
        const isClient = (value: any) =>
          !!value &&
          typeof value === "object" &&
          typeof value.lastSeq === "number" &&
          "selectedSessionId" in value &&
          typeof value.socket?.onmessage === "function";
        let client: any;
        for (const selector of selectors) {
          const element = document.querySelector(selector) as any;
          if (!element) continue;
          const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
          for (let fiber = key ? element[key] : undefined; fiber && !client; fiber = fiber.return)
            for (let hook = fiber.memoizedState; hook && typeof hook === "object" && "next" in hook; hook = hook.next)
              if (isClient(hook.memoizedState?.current)) {
                client = hook.memoizedState.current;
                break;
              }
          if (client) break;
        }
        if (!client) return { error: "no direct client found through the pane's fiber" };
        if (client.selectedSessionId !== session) return { error: `the client shows ${client.selectedSessionId}` };
        const w = window as any;
        w.__settleClient = client;
        let seq = client.lastSeq as number;
        const id = JSON.stringify(session);
        const event = (kind: string, msg: string) =>
          `{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":${id},"seq":${++seq},"at":${Date.now()},"dir":"mux","kind":"${kind}","msg":${msg}}}`;
        const update = (body: string) =>
          `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":${id},"update":${body},"_meta":{"acpmux":{"seq":${++seq},"at":${Date.now()}}}}}`;
        const call = "return-bottom-settles-load";
        let chunks = 0;
        let lines = 0;
        w.__settleChunk = () =>
          update(
            `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":${JSON.stringify(`word ${++chunks} `)}}}`,
          );
        w.__settleLine = () =>
          update(
            `{"sessionUpdate":"tool_call_update","toolCallId":"${call}","status":"in_progress","_meta":{"terminal_output":{"data":${JSON.stringify(`[${++lines}] compiling module${lines % 97}.ts ok\n`)}}}}`,
          );
        w.__settleCallDone = () =>
          update(`{"sessionUpdate":"tool_call_update","toolCallId":"${call}","status":"completed"}`);
        w.__settleEnd = () => event("turn_result", `{"stopReason":"end_turn"}`);
        w.__settlePush = (frames: string[]) => {
          const socket = client.socket as Socket | undefined;
          for (const data of frames) if (socket && socket.readyState === 1) socket.onmessage?.({ data });
        };
        w.__settlePush([
          event("user_message", `{"text":"Build it"}`),
          event("turn_started", "{}"),
          update(
            `{"sessionUpdate":"tool_call","toolCallId":"${call}","title":"Run bun run build","kind":"execute","status":"in_progress","rawInput":{"command":"bun run build"}}`,
          ),
        ]);
        const frames: string[] = [];
        for (let index = 0; index < 20; index += 1) frames.push(w.__settleChunk(), w.__settleLine());
        w.__settlePush(frames);
        return {};
      },
      { session: seeded.session as string, selectors: [PROMPT, ".acpmux-scroll", ".acpmux-composer"] },
    )) as { error?: string };
    expect(started.error).toBeUndefined();

    const settle = () =>
      page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    // The streamed turn drawn and followed: the view sits at the end, and the transcript's height and row count held
    // for 10 frames in a row (as agent-pane-older-paging-return-keeps-rows.test.ts waits).
    await page.waitForFunction(
      () => {
        const w = window as any;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (!scroller) return false;
        const distance = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
        const shape = `${scroller.scrollHeight}:${scroller.querySelectorAll(".acpmux-row").length}`;
        w.__settleQuiet =
          w.__settleQuiet?.shape === shape ? { shape, frames: w.__settleQuiet.frames + 1 } : { shape, frames: 0 };
        return w.__settleClient.following === true && Math.abs(distance) < 1 && w.__settleQuiet.frames >= 10;
      },
      null,
      { timeout: 10_000, polling: "raf" },
    );

    // The reader scrolls up a screen and a half; the turn streams on while they read, past what the client holds
    // before it sheds while following, as in the run that saw the gap.
    const box = (await page.locator(".acpmux-scroll").first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.wheel(0, -1500);
    await page.waitForFunction(() => (window as any).__settleClient.following === false, null, { timeout: 10_000 });
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const w = window as any;
          const pump = () => {
            const frames: string[] = [];
            for (let index = 0; index < 400; index += 1) frames.push(w.__settleLine());
            frames.push(w.__settleChunk());
            w.__settlePush(frames);
            if (w.__settleClient.events.length <= 4_500) setTimeout(pump, 16);
            else resolve();
          };
          pump();
        }),
    );
    await settle();
    expect(await page.evaluate(() => (window as any).__settleClient.following)).toBe(false);

    // The scroll event that brings the reader back to following: the turn's last rows land then, the call's last
    // line and its end in that event, the reply's last words and the turn's end on the frames after. Every frame from
    // there on, the distance from the scroller's end.
    await page.evaluate(
      ({ watchMs }) => {
        const w = window as any;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const client = w.__settleClient;
        const samples: { at: number; distance: number; following: boolean }[] = [];
        w.__settleSamples = samples;
        const distance = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
        const onScroll = () => {
          if (!client.following) return;
          scroller.removeEventListener("scroll", onScroll);
          const back = performance.now();
          w.__settleBack = { distance: distance() };
          w.__settlePush([w.__settleChunk(), w.__settleLine(), w.__settleCallDone()]);
          // Each painted frame is read once it has painted; the reply's last words go in the second frame after the
          // return and the turn's end in the third, each in that frame's callbacks.
          let frame = 0;
          w.cmuxAfterPaint(
            () => {
              const at = performance.now() - back;
              samples.push({ at: Math.round(at), distance: distance(), following: client.following as boolean });
              if (at < watchMs) return true;
              w.__settleDone = true;
              return false;
            },
            () => {
              frame += 1;
              if (frame === 2) w.__settlePush([w.__settleChunk(), w.__settleChunk()]);
              if (frame === 3) w.__settlePush([w.__settleEnd()]);
            },
          );
        };
        scroller.addEventListener("scroll", onScroll);
      },
      { watchMs: WATCH_MS },
    );
    for (let step = 0; step < 20; step += 1) {
      await page.mouse.wheel(0, 2000);
      await settle();
      if (await page.evaluate(() => (window as any).__settleBack !== undefined)) break;
    }
    const back = await page.evaluate(() => (window as any).__settleBack);
    expect(back, "a wheel down brought the view back to following").toBeDefined();
    await page.waitForFunction(() => (window as any).__settleDone === true, null, { timeout: 10_000 });
    const samples = (await page.evaluate(() => (window as any).__settleSamples)) as {
      at: number;
      distance: number;
      following: boolean;
    }[];
    await page.close();

    // At the end: within the browser's sub-pixel rounding of the offset.
    const atEnd = (sample: { distance: number }) => Math.abs(sample.distance) < 1;
    const firstAtEnd = samples.findIndex(atEnd);
    const away = firstAtEnd < 0 ? samples : samples.slice(firstAtEnd).filter((sample) => !atEnd(sample));
    const worst = Math.max(...samples.map((sample) => sample.distance));
    const at300 = samples.find((sample) => sample.at >= 300);
    console.log(
      `RETURN-BOTTOM-SETTLES ${JSON.stringify({
        back,
        frames: samples.length,
        lastAt: samples.at(-1)?.at,
        firstAtEndMs: firstAtEnd < 0 ? null : samples[firstAtEnd]!.at,
        at300: at300 ?? null,
        worstPx: worst,
        awayAfterEnd: away.slice(0, 10),
        samples: samples.filter((_, index) => index % 6 === 0).map((sample) => [sample.at, sample.distance]),
      })}`,
    );

    expect(samples.at(-1)!.at, "sampled for at least a second after the return").toBeGreaterThanOrEqual(1_000);
    expect(
      samples.every((sample) => sample.following),
      "the view follows throughout",
    ).toBe(true);
    expect(firstAtEnd, `px from the end ${SETTLE_MS} ms after the return: ${at300?.distance}`).toBeGreaterThanOrEqual(
      0,
    );
    expect(samples[firstAtEnd]!.at, "ms after the return to sit at the end").toBeLessThanOrEqual(SETTLE_MS);
    expect(
      away.map((sample) => [sample.at, sample.distance]),
      "frames off the end after it got there",
    ).toEqual([]);
  });
});
