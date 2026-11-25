// A reader who scrolls up while a chat streams under load, then comes back to its latest row, keeps every row in
// view: the shed that comes before the next render cuts none of them.
//
// Each scroll event runs the older-history check (`checkOlder`), which tells the client the oldest row in view while
// the view follows (`keepFromInView`, `setKeepFrom`). It ran before the event's follow state was set (`queueScroll`),
// so the event that brought the reader back read the view as scrolled up and named no row, while the client already
// followed again (`setFollowing`). A record that came before the next render (a socket frame between the scroll
// event and the frame's commit) shed by the count alone and cut the rows the view showed above the turn (#44776 F1).
//
// The load goes in as the host's push does: raw frames through the client's transport socket, the client found
// through React's fiber above the composer (as agent-pane-older-paging-at-bottom.test.ts finds it). The frame that
// sheds is pushed from a scroll listener the scroller runs right after React's own: the earliest a frame can come
// after the reader's scroll back.
/// <reference types="bun" />
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-older-paging-return-keeps-rows.test.ts", async () => {
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

  test("a reader back at the latest row keeps the rows in view through the next shed", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 1000 } });
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
        w.__returnClient = client;
        const counts = { shedOlderHeld: 0 };
        w.__returnCounts = counts;
        const shed = client.shedOlderHeld;
        client.shedOlderHeld = function (this: unknown, ...args: unknown[]) {
          counts.shedOlderHeld += 1;
          return shed.apply(this, args);
        };
        let seq = client.lastSeq as number;
        const id = JSON.stringify(session);
        const event = (kind: string, msg: string) =>
          `{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":${id},"seq":${++seq},"at":${Date.now()},"dir":"mux","kind":"${kind}","msg":${msg}}}`;
        const update = (body: string) =>
          `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":${id},"update":${body},"_meta":{"acpmux":{"seq":${++seq},"at":${Date.now()}}}}}`;
        const call = "return-keeps-rows-load";
        let chunks = 0;
        let lines = 0;
        w.__returnChunk = () =>
          update(
            `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":${JSON.stringify(`word ${++chunks} `)}}}`,
          );
        w.__returnLine = () =>
          update(
            `{"sessionUpdate":"tool_call_update","toolCallId":"${call}","status":"in_progress","_meta":{"terminal_output":{"data":${JSON.stringify(`[${++lines}] compiling module${lines % 97}.ts ok\n`)}}}}`,
          );
        w.__returnEnd = () => event("turn_result", `{"stopReason":"end_turn"}`);
        w.__returnPush = (frames: string[]) => {
          const socket = client.socket as Socket | undefined;
          for (const data of frames) if (socket && socket.readyState === 1) socket.onmessage?.({ data });
        };
        w.__returnPromptSeq = seq + 1;
        w.__returnPush([
          event("user_message", `{"text":"Build it"}`),
          event("turn_started", "{}"),
          update(
            `{"sessionUpdate":"tool_call","toolCallId":"${call}","title":"Run bun run build","kind":"execute","status":"in_progress","rawInput":{"command":"bun run build"}}`,
          ),
        ]);
        const frames: string[] = [];
        for (let index = 0; index < 20; index += 1) frames.push(w.__returnChunk(), w.__returnLine());
        w.__returnPush(frames);
        return {};
      },
      { session: seeded.session as string, selectors: [PROMPT, ".acpmux-scroll", ".acpmux-composer"] },
    )) as { error?: string };
    expect(started.error).toBeUndefined();

    // The rows the reader sees at the latest row, before scrolling away: those the client holds under their own id.
    const settle = () =>
      page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    // The transcript's layout stopped changing: its height and row count held for 10 frames in a row.
    const quiet = () =>
      page.waitForFunction(
        () => {
          const w = window as any;
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!scroller) return false;
          const shape = `${scroller.scrollHeight}:${scroller.querySelectorAll(".acpmux-row").length}`;
          w.__returnQuiet =
            w.__returnQuiet?.shape === shape ? { shape, frames: w.__returnQuiet.frames + 1 } : { shape, frames: 0 };
          return w.__returnQuiet.frames >= 10;
        },
        null,
        { polling: "raf", timeout: 10_000 },
      );
    // The streamed turn's 40 chunks and lines are drawn.
    await quiet();
    const inView = () =>
      page.evaluate((rowSelector) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const box = scroller.getBoundingClientRect();
        const client = (window as any).__returnClient;
        return [...scroller.querySelectorAll<HTMLElement>(rowSelector)]
          .filter((row) => {
            const rect = row.getBoundingClientRect();
            return rect.bottom > box.top + 1 && rect.top < box.bottom - 1;
          })
          .map((row) => ({ id: row.dataset.rowId!, seq: client.rows.orderOf(row.dataset.rowId!) as number }))
          .filter((row) => Number.isFinite(row.seq));
      }, TRANSCRIPT_ROW);
    const before = await inView();
    const promptSeq = (await page.evaluate(() => (window as any).__returnPromptSeq)) as number;
    console.log(`RETURN-KEEPS-ROWS view ${JSON.stringify({ before, promptSeq })}`);
    // The view shows rows from before the streamed turn, which a shed by the count alone lets go.
    expect(
      before.some((row) => row.seq < promptSeq),
      "rows in view from before the turn",
    ).toBe(true);

    // The reader scrolls up a screen and a half; the stream goes on while they read, past what the client holds
    // before it sheds (`HELD_RECORDS`), which it does not while the view is scrolled up.
    const box = (await page.locator(".acpmux-scroll").first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.wheel(0, -1500);
    await page.waitForFunction(() => (window as any).__returnClient.following === false, null, { timeout: 10_000 });
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const w = window as any;
          const pump = () => {
            const frames: string[] = [];
            for (let index = 0; index < 400; index += 1) frames.push(w.__returnLine());
            frames.push(w.__returnChunk());
            w.__returnPush(frames);
            if (w.__returnClient.events.length <= 4_500) setTimeout(pump, 16);
            else resolve();
          };
          pump();
        }),
    );
    await settle();
    const up = (await page.evaluate(() => {
      const client = (window as any).__returnClient;
      return {
        held: client.events.length as number,
        following: client.following as boolean,
        sheds: (window as any).__returnCounts.shedOlderHeld as number,
        loadingOlder: client.loadingOlder !== undefined,
      };
    })) as Record<string, unknown>;
    console.log(`RETURN-KEEPS-ROWS up ${JSON.stringify(up)}`);
    expect(up.following).toBe(false);

    // The first scroll event that brings the reader back to following: a frame arrives before the next render.
    await page.evaluate(() => {
      const w = window as any;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const client = w.__returnClient;
      const onScroll = () => {
        if (!client.following) return;
        scroller.removeEventListener("scroll", onScroll);
        const held = client.events.length;
        w.__returnAtBack = {
          keepFrom: client.keepFromRow ?? null,
          loadingOlder: client.loadingOlder !== undefined,
          held,
        };
        w.__returnPush([w.__returnChunk(), w.__returnLine(), w.__returnEnd()]);
        w.__returnAtBack.heldAfter = client.events.length;
      };
      scroller.addEventListener("scroll", onScroll);
      w.__returnListener = onScroll;
    });
    for (let step = 0; step < 20; step += 1) {
      await page.mouse.wheel(0, 2000);
      await settle();
      if (await page.evaluate(() => (window as any).__returnAtBack !== undefined)) break;
    }
    const back = (await page.evaluate(() => (window as any).__returnAtBack)) as Record<string, unknown> | undefined;
    // Following is on again, and the turn end's rows (and any shed they bring) are drawn.
    await page.waitForFunction(() => (window as any).__returnClient.following === true, null, { timeout: 10_000 });
    await quiet();
    const shed = (await page.evaluate(
      (ids) => {
        const client = (window as any).__returnClient;
        return {
          lost: ids.filter((id: string) => !Number.isFinite(client.rows.orderOf(id))),
          sheds: (window as any).__returnCounts.shedOlderHeld as number,
          held: client.events.length as number,
          following: client.following as boolean,
          atEnd: (() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
          })(),
        };
      },
      before.map((row) => row.id),
    )) as { lost: string[]; sheds: number; held: number; following: boolean; atEnd: number };
    const after = await inView();
    // Logged only: whether the view settles at the latest row within 5 s once the turn's end lands under it.
    const settledAtEnd = await page
      .waitForFunction(
        () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 4;
        },
        null,
        { timeout: 5_000 },
      )
      .then(
        () => true,
        () => false,
      );
    await page.close();
    console.log(`RETURN-KEEPS-ROWS back ${JSON.stringify({ back, shed, after, settledAtEnd })}`);

    expect(back, "a scroll event brought the view back to following").toBeDefined();
    expect(back!.loadingOlder, "no older page in flight at the return").toBe(false);
    // The frame shed: the client let go of its oldest records while the view followed.
    expect(back!.heldAfter as number, "records held after the frame").toBeLessThan(back!.held as number);
    expect(shed.following, "the view follows the latest row again").toBe(true);
    // None of the rows the reader saw at the latest row went with them.
    expect(shed.lost, "rows in view shed before the next render").toEqual([]);
  });
});
