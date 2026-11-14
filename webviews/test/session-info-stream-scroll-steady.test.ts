// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// Session Info, every section open, holds still while a turn thinks, runs tool calls and background
// commands, and the reader scrolls slowly down through it (Leo, 2026-11-07: "im still seeing session
// info flash (maybe others, but mostly expanded session info) aka flicker aka rerender aka disappear and
// reappear quickly when im slowly scrolling down as you're doing the thinking/tool calls").
//
// The flash: a background command brings the running tray in over the composer, so the composer's
// stack grows. An expanded panel over the chat ends above that stack (its foot, SessionInfo.tsx
// useDockHeight). The foot followed a frame or more late (a scheduled render) and then glided up
// (a max-height transition), so for several frames the card's lower part lay over the tray. That
// overlap set data-glass-keeps-underlay (ui/glass/seeThroughBlur.ts), which takes the card off the App's
// own glass (glass.css host glass) onto the page's own and back: the card changed its look for those
// frames, at every tool call that brought the tray in or out.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a seeded chat,
// its page marked see-through and its host glass reported to a stand-in App that answers a frame later.
// Every painted frame is read: the panel's node and each section slot's node stay the same, its glass
// stays the App's (drawn, no kept underlay), and it never reaches over the composer's stack.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-info-stream-scroll-steady.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
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

  /// A turn as an agent runs one: its plan ticks, it thinks, runs a command (every other one in the
  /// background, which brings the running tray in), reads, edits and writes, eight times.
  const stream = (page: Page, target: string) =>
    page.evaluate(async (target) => {
      // The pane's dev server serves src/agent-session/acpmux at its root.
      const mockUrl = "/mock.ts";
      const mock = (await import(/* @vite-ignore */ mockUrl)).MockAcpmuxSocket.live as any;
      const emit = (update: unknown) => mock.emit(target, { update });
      // fixed-wait: an agent's pacing between streamed updates is the behavior under test.
      const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
      for (let round = 0; round < 8; round++) {
        emit({
          sessionUpdate: "plan",
          entries: Array.from({ length: 5 }, (_, step) => ({
            content: `Step ${step + 1}`,
            priority: "medium",
            status: step < round % 5 ? "completed" : step === round % 5 ? "in_progress" : "pending",
          })),
        });
        for (let chunk = 0; chunk < 15; chunk++) {
          emit({
            sessionUpdate: "agent_thought_chunk",
            content: { type: "text", text: `thinking ${round}.${chunk} ` },
          });
          // fixed-wait: an agent's pacing between streamed updates is the behavior under test.
          await wait(16);
        }
        const id = `run-${round}`;
        const background = round % 2 === 0;
        emit({
          sessionUpdate: "tool_call",
          toolCallId: id,
          kind: "execute",
          title: `bun test ${round}`,
          status: "in_progress",
          rawInput: { command: `bun test ${round}`, run_in_background: background },
        });
        for (let tick = 0; tick < 8; tick++) {
          emit({
            sessionUpdate: "tool_call_update",
            toolCallId: id,
            status: "in_progress",
            content: [{ type: "content", content: { type: "text", text: `pass ${tick}\n`.repeat(tick + 1) } }],
          });
          // fixed-wait: an agent's pacing between streamed updates is the behavior under test.
          await wait(40);
        }
        emit({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          ...(background ? { rawOutput: `Command running in background with ID: bg-${round}` } : {}),
        });
        emit({
          sessionUpdate: "tool_call",
          toolCallId: `read-${round}`,
          kind: "read",
          title: `Read src/r${round}.ts`,
          status: "completed",
          locations: [{ path: `/mock/project/src/r${round}.ts` }],
        });
        emit({
          sessionUpdate: "tool_call",
          toolCallId: `edit-${round}`,
          kind: "edit",
          title: `Edit src/f${round}.ts`,
          status: "completed",
          content: [{ type: "diff", path: `/mock/project/src/f${round}.ts`, oldText: "a\n", newText: "a\nb\n" }],
        });
        for (let chunk = 0; chunk < 10; chunk++) {
          emit({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `word ${chunk} ` } });
          // fixed-wait: an agent's pacing between streamed updates is the behavior under test.
          await wait(16);
        }
      }
    }, target);

  // 1000 and 760: the panel lies over the chat, on the App's glass, and stops above the composer's stack.
  // 1400: it pushes the chat (no glass, no foot); its nodes still hold.
  for (const width of [1000, 760, 1400])
    test(`at ${width} px, Session Info holds still while a turn streams tool calls and the reader scrolls`, async () => {
      const page = await browser!.newPage({ viewport: { width, height: 820 } });
      try {
        await installPaintedFrames(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/?mock`);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
        const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(60))) as Record<
          string,
          unknown
        >;
        expect(seeded.error).toBeUndefined();
        const target = String(seeded.session);
        await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
        const toggle = page.locator("button.acpmux-session-info-toggle").first();
        await toggle.waitFor({ timeout: 10_000 });
        if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
        await page.waitForFunction(
          () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
        );
        // Expanded: every section unfolded, Show more open.
        await page.evaluate(async () => {
          const stateUrl = "/session-info/sessionInfoState.ts";
          const state = await import(/* @vite-ignore */ stateUrl);
          state.setSessionInfoMore(true);
          for (const id of [
            "environment",
            "context",
            "usage",
            "connectors",
            "changes",
            "sources",
            "servers",
            "progress",
            "subagents",
            "tasks",
            "alsoHere",
            "outputs",
          ])
            state.setSessionInfoSection(id, true);
        });
        await page.evaluate(async (target) => {
          // The pane's dev server serves src/agent-session/acpmux at its root.
          const mockUrl = "/mock.ts";
          const mock = (await import(/* @vite-ignore */ mockUrl)).MockAcpmuxSocket.live as any;
          mock.emit(target, { mux: "user_message", msg: { text: "Fix the flaky check" } });
          mock.emit(target, { mux: "turn_started" });
        }, target);
        // The reader is a few screens up when the turn gets going.
        const scroller = (await page.locator(".acpmux-scroll").boundingBox())!;
        await page.mouse.move(scroller.x + scroller.width / 3, scroller.y + scroller.height / 2);
        for (let step = 0; step < 8; step++) await page.mouse.wheel(0, -400);
        await page.waitForFunction(() =>
          document
            .querySelector("aside.acpmux-session-info")!
            .getAnimations({ subtree: true })
            .every((animation) => animation.effect?.getComputedTiming().endTime === Infinity),
        );
        const hostGlass = `/@fs${path.join(webviews, "src/ui/glass/hostGlass.ts")}`;
        await page.evaluate(async (hostGlass) => {
          const w = window as any;
          // A see-through page whose host glass a stand-in App draws a frame after each report.
          document.documentElement.setAttribute("data-cmux-see-through", "");
          const { reportHostGlass } = await import(/* @vite-ignore */ hostGlass);
          reportHostGlass(
            document,
            () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
          );
          await new Promise<void>((resolve) => {
            const drawn = () => {
              const panel = document.querySelector("aside.acpmux-session-info");
              if (!panel?.hasAttribute("data-host-glass") || panel.getAttribute("data-host-glass-drawn") === "1")
                resolve();
              // raf-read: waits for the stand-in App's answer to mark the glass drawn; nothing is sampled.
              else requestAnimationFrame(drawn);
            };
            drawn();
          });
          const aside = () => document.querySelector<HTMLElement>("aside.acpmux-session-info");
          const panel = aside()!;
          const slots = new Map(
            [...panel.querySelectorAll("[data-slot]")].map((slot) => [slot.getAttribute("data-slot")!, slot]),
          );
          const seen = {
            frames: 0,
            replaced: 0,
            slotsReplaced: [] as string[],
            looks: new Set<string>(),
            overStack: 0,
            footSteps: 0,
            stack: new Set<number>(),
          };
          w.__seen = seen;
          let lastFoot: number | undefined;
          w.__stop = window.cmuxAfterPaint(() => {
            seen.frames += 1;
            const node = aside();
            if (node !== panel) {
              seen.replaced += 1;
              return true;
            }
            for (const [id, slot] of slots) {
              const now = node.querySelector(`[data-slot="${id}"]`);
              if (now && now !== slot) {
                seen.slotsReplaced.push(id);
                slots.set(id, now);
              }
            }
            const style = getComputedStyle(node);
            seen.looks.add(
              [
                node.className,
                node.getAttribute("data-host-glass-drawn"),
                node.hasAttribute("data-glass-keeps-underlay") ? "keeps-underlay" : "",
                style.opacity,
                style.visibility,
                style.filter,
                style.backgroundColor,
              ].join("|"),
            );
            // The composer's stack: the top of its highest part (useDockHeight).
            const dock = document.querySelector(".acpmux-dock")!;
            let top = Infinity;
            for (const part of [dock, ...dock.children]) {
              const box = part.getBoundingClientRect();
              if (box.height > 0) top = Math.min(top, box.top);
            }
            seen.stack.add(Math.round(top));
            if (node.hasAttribute("data-over-chat")) {
              const bottom = node.getBoundingClientRect().bottom;
              if (bottom > top + 0.5) seen.overStack += 1;
              const foot = Math.round(bottom);
              if (lastFoot !== undefined && foot !== lastFoot) seen.footSteps += 1;
              lastFoot = foot;
            }
            return true;
          });
        }, hostGlass);

        // The reader scrolls slowly down, pausing past the card's scroll hold (heldWhileScrolling.ts),
        // while the turn streams.
        let streamed = false;
        // fixed-wait: the stream's own pacing (below) ends the scroll loop.
        const streaming = stream(page, target).then(() => (streamed = true));
        while (!streamed) {
          for (let step = 0; step < 6 && !streamed; step++) {
            await page.mouse.wheel(0, 12);
            // fixed-wait: a slow trackpad's spacing between wheel steps.
            await page.waitForTimeout(30);
          }
          // fixed-wait: a pause longer than the scroll hold's settle.
          await page.waitForTimeout(320);
        }
        await streaming;
        const seen = (await page.evaluate(() => {
          const w = window as any;
          w.__stop();
          const seen = w.__seen;
          return { ...seen, looks: [...seen.looks], stack: [...seen.stack] };
        })) as {
          frames: number;
          replaced: number;
          slotsReplaced: string[];
          looks: string[];
          overStack: number;
          footSteps: number;
          stack: number[];
        };
        console.log(`SESSION-INFO-STREAM-SCROLL ${width}px ${JSON.stringify(seen)}`);
        expect(seen.frames).toBeGreaterThan(100);
        // The running tray came in: the composer's stack moved under the panel during the run.
        expect(seen.stack.length).toBeGreaterThan(1);
        expect(seen.replaced, "frames the panel's node was gone or replaced").toBe(0);
        expect(seen.slotsReplaced, "section slots drawn anew").toEqual([]);
        expect(seen.looks, "the panel's looks over the run").toHaveLength(1);
        expect(seen.overStack, "frames the panel reached over the composer's stack").toBe(0);
      } finally {
        await page.close();
      }
    });
});
