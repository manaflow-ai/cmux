// A chat that streams while the reader sits at its latest row reads no older history.
//
// Under load (a reply at 60 chunks/s and a shell call printing 2,000 lines/s, the composer-typing bench's heavy
// mode) the client lets go of its oldest held records past `HELD_RECORDS` (`shedOlderHeld`). The records it keeps
// are mostly one call's output, a few rows tall, so the transcript saw less than `OLDER_AHEAD_VIEWPORTS` screens of
// rows above the view and asked for an older page at once (`checkOlder`). The page brought the shed records back,
// the next streamed record shed them again, and each page that landed refolded every held record
// (`rebuildKeepingLiveState`): 74 older pages and 70 refolds in 9.8 s, about a third of the main thread while the
// person typed (35.7 of 109 ms per key). An older page is read only when the reader nears the top of what is held
// (a scroll up, a find, a jump), never while the view follows the latest row, and the shed keeps the rows in view
// (`setKeepFrom`), so what is held still fills the view.
//
// The load goes in as the host's push does: raw frames through the client's transport socket, the client found
// through React's fiber above the composer (as bench/composer-typing.bench.ts's stream mode finds it).
/// <reference types="bun" />
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-older-paging-at-bottom.test.ts", async () => {
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

  test("a chat streaming at its latest row reads no older page and refolds nothing", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 820 } });
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
        // Count what the stream makes the client do, from here on.
        const counts: Record<string, number> = { shedOlderHeld: 0, fetchOlder: 0, rebuildKeepingLiveState: 0 };
        (window as any).__olderPaging = counts;
        (window as any).__olderClient = client;
        for (const name of Object.keys(counts)) {
          const own = client[name];
          if (typeof own !== "function") return { error: `the client has no ${name}` };
          client[name] = function (this: unknown, ...args: unknown[]) {
            counts[name]! += 1;
            return own.apply(this, args);
          };
        }
        let seq = client.lastSeq as number;
        const id = JSON.stringify(session);
        const event = (kind: string, msg: string) =>
          `{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":${id},"seq":${++seq},"at":${Date.now()},"dir":"mux","kind":"${kind}","msg":${msg}}}`;
        const update = (body: string) =>
          `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":${id},"update":${body},"_meta":{"acpmux":{"seq":${++seq},"at":${Date.now()}}}}}`;
        const call = "older-paging-load";
        let chunks = 0;
        let lines = 0;
        const chunk = () =>
          update(
            `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":${JSON.stringify(`word ${++chunks} `)}}}`,
          );
        const line = () =>
          update(
            `{"sessionUpdate":"tool_call_update","toolCallId":"${call}","status":"in_progress","_meta":{"terminal_output":{"data":${JSON.stringify(`[${++lines}] compiling module${lines % 97}.ts ok\n`)}}}}`,
          );
        const push = (frames: string[]) => {
          const socket = client.socket as Socket | undefined;
          for (const data of frames) if (socket && socket.readyState === 1) socket.onmessage?.({ data });
        };
        push([
          event("user_message", `{"text":"Build it"}`),
          event("turn_started", "{}"),
          update(
            `{"sessionUpdate":"tool_call","toolCallId":"${call}","title":"Run bun run build","kind":"execute","status":"in_progress","rawInput":{"command":"bun run build"}}`,
          ),
        ]);
        // As the host's pacer pushes: every frame due since the last, once per ~16 ms, for 6 s.
        const t0 = performance.now();
        let sentChunks = 0;
        let sentLines = 0;
        const pump = () => {
          const elapsed = (performance.now() - t0) / 1000;
          const frames: string[] = [];
          for (; sentChunks < Math.floor(Math.min(elapsed, 6) * 60); sentChunks += 1) frames.push(chunk());
          for (; sentLines < Math.floor(Math.min(elapsed, 6) * 2000); sentLines += 1) frames.push(line());
          push(frames);
          if (elapsed < 6) setTimeout(pump, 16);
          else {
            // The records the streamed turn added: its prompt, start and call, then every chunk and line.
            (window as any).__olderStreamed = 3 + sentChunks + sentLines;
            (window as any).__olderPagingDone = true;
          }
        };
        setTimeout(pump, 16);
        return {};
      },
      { session: seeded.session as string, selectors: [PROMPT, ".acpmux-scroll", ".acpmux-composer"] },
    )) as { error?: string };
    expect(started.error).toBeUndefined();
    await page.waitForFunction(() => (window as any).__olderPagingDone === true, null, { timeout: 60_000 });
    // A page asked for in the stream's last frames lands (and refolds) before `loadingOlder` clears.
    await page.waitForFunction(() => (window as any).__olderClient.loadingOlder === undefined, null, {
      timeout: 30_000,
    });
    const result = (await page.evaluate(() => ({
      counts: (window as any).__olderPaging as Record<string, number>,
      held: (window as any).__olderClient.events.length as number,
      streamed: (window as any).__olderStreamed as number,
      following: (() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
      })(),
    }))) as {
      counts: Record<string, number>;
      held: number;
      streamed: number;
      following: number;
    };
    await page.close();
    console.log(`OLDER-PAGING-AT-BOTTOM ${JSON.stringify(result)}`);

    // The load is heavy enough to let go of older records, and the reader stayed at the latest row.
    expect(result.counts.shedOlderHeld, "sheds while streaming").toBeGreaterThan(0);
    expect(result.following, "px from the latest row").toBeLessThan(4);
    // What it keeps for the rows in view stays bounded: of the records from before the streamed turn, at most a
    // page (`HELD_KEPT`, 2,000). The one call's own records stay while its row spans them, as on base.
    expect(result.held - result.streamed, "records held from before the streamed turn").toBeLessThanOrEqual(2_000);
    // Nothing read the shed history back, and nothing refolded the held window.
    expect(result.counts.fetchOlder, "older pages read at the latest row").toBe(0);
    expect(result.counts.rebuildKeepingLiveState, "refolds of the held window").toBe(0);
  });
});
