// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// Session Info, every section open, never blanks or draws anew while the reader slowly scrolls and a
// turn streams its thinking and tool calls (Leo, 2026-11-07: "im still seeing session info flash
// (maybe others, but mostly expanded session info) aka flicker aka rerender aka disappear and reappear
// quickly when im slowly scrolling down as you're doing the thinking/tool calls").
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a seeded chat,
// Session Info open and expanded. A turn streams (a plan, thinking, commands, reads, edits, a reply)
// while the wheel moves slowly down, in steps and pauses, over the panel's own body, then over the
// transcript. Two reads of the same run:
//   frames  every painted frame (support/paintedFrames.ts): the panel's node, its section slots and
//           rows kept, no frame where a held-back rows box (WindowedRows.tsx) shows inside the body's
//           window, and the body's edge fade switched only where the scroll crossed an edge;
//   pixels  Chromium's delivered frames (CDP screencast) of the panel's box: a frame whose drawn
//           content drops to under half of its neighbours' and comes back is a blank, a flash.
// SESSION-INFO-SCROLL-FLICKER lines print the counts, the bench's before/after numbers.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { PNG } from "pngjs";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-info-scroll-flicker.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let safari: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
    safari = await webkit.launch({ headless: true }).catch(() => undefined);
  });
  afterAll(async () => {
    await browser?.close();
    await safari?.close();
    await vite?.close();
  });

  /// A turn as an agent runs one: its plan ticks, it thinks, runs a command (every other one in the
  /// background), reads, edits and replies, `rounds` times.
  const stream = (page: Page, target: string, rounds: number) =>
    page.evaluate(
      async ({ target, rounds }) => {
        const mockUrl = "/mock.ts";
        const mock = (await import(/* @vite-ignore */ mockUrl)).MockAcpmuxSocket.live as any;
        const emit = (update: unknown) => mock.emit(target, { update });
        // fixed-wait: an agent's pacing between streamed updates is the behavior under test.
        const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
        for (let round = 0; round < rounds; round++) {
          emit({
            sessionUpdate: "plan",
            entries: Array.from({ length: 5 }, (_, step) => ({
              content: `Step ${step + 1}`,
              priority: "medium",
              status: step < round % 5 ? "completed" : step === round % 5 ? "in_progress" : "pending",
            })),
          });
          for (let chunk = 0; chunk < 15; chunk++) {
            emit({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: `thinking ${round}.${chunk} ` } });
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
      },
      { target, rounds },
    );

  type Seen = {
    looks: string[];
    lookChanges: number;
    underWrites: number;
    frames: number;
    replaced: number;
    slotsReplaced: number;
    rowsRemoved: number;
    rowsRemovedFrames: number;
    removedKinds: Record<string, number>;
    restShown: number;
    fadeFlips: number;
    boxMoves: number;
    scrolledPx: number;
  };

  async function openPanel(
    engine: Browser,
    width: number,
    height: number,
    seeThrough: boolean,
  ): Promise<{ page: Page; target: string }> {
    const page = await engine.newPage({ viewport: { width, height } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(120))) as Record<string, unknown>;
    expect(seeded.error).toBeUndefined();
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
    await page.waitForFunction(() =>
      document
        .querySelector("aside.acpmux-session-info")!
        .getAnimations({ subtree: true })
        .every((animation) => animation.effect?.getComputedTiming().endTime === Infinity),
    );
    if (seeThrough) {
      // A see-through page whose host glass a stand-in App draws a frame after each report, as the App's.
      const hostGlass = `/@fs${path.join(webviews, "src/ui/glass/hostGlass.ts")}`;
      await page.evaluate(async (hostGlass) => {
        document.documentElement.setAttribute("data-cmux-see-through", "");
        const { reportHostGlass } = await import(/* @vite-ignore */ hostGlass);
        reportHostGlass(
          document,
          () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        );
      }, hostGlass);
      await page.waitForFunction(() => {
        const panel = document.querySelector("aside.acpmux-session-info");
        return !panel?.hasAttribute("data-host-glass") || panel.hasAttribute("data-host-glass-drawn");
      });
    }
    return { page, target: String(seeded.session) };
  }

  /// Starts the per-frame read of the panel; `__seen` holds the counts.
  const sample = (page: Page) =>
    page.evaluate(async () => {
      const w = window as any;
      const aside = () => document.querySelector<HTMLElement>("aside.acpmux-session-info");
      const panel = aside()!;
      const body = panel.querySelector<HTMLElement>(".acpmux-session-info__body")!;
      const slots = new Map(
        [...panel.querySelectorAll("[data-slot]")].map((slot) => [slot.getAttribute("data-slot")!, slot]),
      );
      const seen = {
        frames: 0,
        replaced: 0,
        slotsReplaced: 0,
        rowsRemoved: 0,
        rowsRemovedFrames: 0,
        removedKinds: {} as Record<string, number>,
        restShown: 0,
        fadeFlips: 0,
        boxMoves: 0,
        scrolledPx: 0,
        looks: [] as string[],
        lookChanges: 0,
        underWrites: 0,
      };
      w.__seen = seen;
      let look = "";
      // The in-place blur under the glass (ui/glass/seeThroughBlur.ts): each write of a covered
      // element's filter repaints that part of the chat.
      const under = new MutationObserver((records) => {
        for (const record of records)
          if (record.attributeName === "data-glass-under" || (record.target as HTMLElement).closest?.(".acpmux-stage"))
            seen.underWrites += 1;
      });
      const stage = document.querySelector(".acpmux-stage");
      if (stage) under.observe(stage, { subtree: true, attributes: true, attributeFilter: ["data-glass-under", "style"] });
      let removedThisFrame = 0;
      const mutations = new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === "attributes") {
            if (record.target === body && record.attributeName?.startsWith("data-fade")) seen.fadeFlips += 1;
            continue;
          }
          for (const node of record.removedNodes) {
            if (node.nodeType !== 1) continue;
            const element = node as Element;
            const rows = element.matches("li, [data-slot], .acpmux-session-info-row")
              ? 1
              : element.querySelectorAll("li, .acpmux-session-info-row").length;
            if (!rows) continue;
            removedThisFrame += rows;
            seen.rowsRemoved += rows;
            const kind = (element.className && String(element.className).split(" ")[0]) || element.tagName;
            seen.removedKinds[kind] = (seen.removedKinds[kind] ?? 0) + rows;
          }
        }
      });
      mutations.observe(panel, {
        subtree: true,
        childList: true,
        attributes: true,
        attributeFilter: ["data-fade-top", "data-fade-bottom"],
      });
      const box0 = panel.getBoundingClientRect();
      const top0 = body.scrollTop;
      let maxTop = top0;
      const stop = window.cmuxAfterPaint(() => {
        seen.frames += 1;
        if (removedThisFrame) seen.rowsRemovedFrames += 1;
        removedThisFrame = 0;
        const node = aside();
        if (node !== panel) {
          seen.replaced += 1;
          return true;
        }
        for (const [id, slot] of slots) {
          const now = node.querySelector(`[data-slot="${id}"]`);
          if (now && now !== slot) {
            seen.slotsReplaced += 1;
            slots.set(id, now);
          }
        }
        const style = getComputedStyle(node);
        const now = [
          node.className,
          node.getAttribute("data-host-glass-drawn"),
          node.hasAttribute("data-glass-keeps-underlay") ? "keeps-underlay" : "",
          node.hasAttribute("data-glass-over") ? "over" : "",
          style.opacity,
          style.backgroundColor,
        ].join("|");
        if (look && now !== look) seen.lookChanges += 1;
        if (!seen.looks.includes(now)) seen.looks.push(now);
        look = now;
        const box = node.getBoundingClientRect();
        if (Math.abs(box.left - box0.left) > 0.5 || Math.abs(box.top - box0.top) > 0.5) seen.boxMoves += 1;
        const view = body.getBoundingClientRect();
        for (const rest of node.querySelectorAll("[data-rows-rest]")) {
          const r = rest.getBoundingClientRect();
          if (r.height > 0 && r.bottom > view.top + 1 && r.top < view.bottom - 1) {
            seen.restShown += 1;
            break;
          }
        }
        maxTop = Math.max(maxTop, body.scrollTop);
        seen.scrolledPx = Math.round(maxTop - top0);
        return true;
      });
      w.__stopSeen = () => {
        stop();
        mutations.disconnect();
        under.disconnect();
        return w.__seen;
      };
    });

  /// Chromium's delivered frames of `crop`, as PNG, from start to `stop`.
  async function screencast(page: Page) {
    const cdp = await page.context().newCDPSession(page);
    const frames: { data: string; timestamp: number }[] = [];
    cdp.on("Page.screencastFrame", (event: { data: string; sessionId: number; metadata: { timestamp?: number } }) => {
      void cdp.send("Page.screencastFrameAck", { sessionId: event.sessionId }).catch(() => undefined);
      if (frames.length < 900) frames.push({ data: event.data, timestamp: event.metadata.timestamp ?? 0 });
    });
    await cdp.send("Page.startScreencast", { format: "png", everyNthFrame: 1 });
    return async () => {
      await cdp.send("Page.stopScreencast");
      await cdp.detach();
      return frames.sort((a, b) => a.timestamp - b.timestamp);
    };
  }

  /// Per delivered frame, how much the panel's box draws (pixels far from its own fill), and the frames
  /// that drop under half of both neighbours' and come back: a blank or a flash.
  function pixelStats(
    frames: { data: string }[],
    crop: { x: number; y: number; width: number; height: number },
    dumpTo?: string,
  ) {
    const ink: number[] = [];
    const pngs: PNG[] = [];
    for (const frame of frames) {
      const png = PNG.sync.read(Buffer.from(frame.data, "base64"));
      pngs.push(png);
      // The fill: the crop's most common luminance bucket.
      const histogram = new Uint32Array(64);
      const lum = (offset: number) =>
        (png.data[offset]! * 0.299 + png.data[offset + 1]! * 0.587 + png.data[offset + 2]! * 0.114) | 0;
      const x0 = Math.max(0, crop.x);
      const y0 = Math.max(0, crop.y);
      const x1 = Math.min(png.width, crop.x + crop.width);
      const y1 = Math.min(png.height, crop.y + crop.height);
      for (let y = y0; y < y1; y += 2)
        for (let x = x0; x < x1; x += 2) histogram[lum((y * png.width + x) * 4) >> 2]! += 1;
      let fill = 0;
      for (let bucket = 1; bucket < 64; bucket++) if (histogram[bucket]! > histogram[fill]!) fill = bucket;
      const base = fill * 4 + 2;
      let count = 0;
      for (let y = y0; y < y1; y += 2)
        for (let x = x0; x < x1; x += 2) if (Math.abs(lum((y * png.width + x) * 4) - base) > 40) count += 1;
      ink.push(count);
    }
    const sorted = [...ink].sort((a, b) => a - b);
    const median = sorted[Math.floor(sorted.length / 2)] ?? 0;
    const blank = ink.flatMap((value, i) => (median > 0 && value < median * 0.35 ? [i] : []));
    const flashes = ink.flatMap((value, i) => {
      const before = ink[i - 1];
      const after = ink[i + 1];
      return before !== undefined && after !== undefined && value < Math.min(before, after) * 0.5 ? [i] : [];
    });
    if (dumpTo)
      for (const i of [...new Set([...blank, ...flashes])].slice(0, 6)) {
        void writeFile(path.join(dumpTo, `frame-${i}.png`), PNG.sync.write(pngs[i]!));
        if (pngs[i - 1]) void writeFile(path.join(dumpTo, `frame-${i - 1}-before.png`), PNG.sync.write(pngs[i - 1]!));
      }
    return { delivered: frames.length, median, blank: blank.length, flashes: flashes.length };
  }

  // 1000: the panel lies over the chat, on glass, above the composer; 1400: it floats in the gutter. The
  // App's page is see-through (its glass under the page) or opaque; WebKit draws its own backdrop.
  const CASES = [
    { engine: "chromium", width: 1000, glass: "see-through" },
    { engine: "chromium", width: 1000, glass: "opaque" },
    { engine: "chromium", width: 1400, glass: "opaque" },
    { engine: "webkit", width: 1000, glass: "opaque" },
  ] as const;
  for (const { engine, width, glass } of CASES)
    for (const over of ["panel", "transcript"] as const)
      test(`${engine} ${glass} at ${width} px: scrolling the ${over} while a turn streams never blanks or redraws Session Info`, async () => {
        const which = engine === "webkit" ? safari : browser;
        if (!which) return;
        const { page, target } = await openPanel(which, width, 760, glass === "see-through");
        const chromiumPage = engine === "chromium";
        try {
          const panelBox = (await page.locator("aside.acpmux-session-info").boundingBox())!;
          const scrollable = await page.evaluate(() => {
            const body = document.querySelector<HTMLElement>(".acpmux-session-info__body")!;
            return body.scrollHeight - body.clientHeight;
          });
          if (over === "transcript") {
            const scroller = (await page.locator(".acpmux-scroll").boundingBox())!;
            await page.mouse.move(scroller.x + scroller.width / 3, scroller.y + scroller.height / 2);
            for (let step = 0; step < 8; step++) await page.mouse.wheel(0, -400);
          } else {
            await page.mouse.move(panelBox.x + panelBox.width / 2, panelBox.y + panelBox.height / 2);
          }
          await sample(page);
          const stopCast = chromiumPage ? await screencast(page) : async () => [];
          await page.evaluate((target) => {
            void import(/* @vite-ignore */ "/mock.ts").then(({ MockAcpmuxSocket }) => {
              const mock = MockAcpmuxSocket.live as any;
              mock.emit(target, { mux: "user_message", msg: { text: "Fix the flaky check" } });
              mock.emit(target, { mux: "turn_started" });
            });
          }, target);
          let streamed = false;
          const streaming = stream(page, target, 4).then(() => (streamed = true));
          while (!streamed) {
            for (let step = 0; step < 6 && !streamed; step++) {
              await page.mouse.wheel(0, 12);
              // fixed-wait: a slow trackpad's spacing between wheel steps.
              await page.waitForTimeout(30);
            }
            // fixed-wait: a pause between strokes, as a reader's.
            await page.waitForTimeout(240);
          }
          await streaming;
          const frames = await stopCast();
          const seen = (await page.evaluate(() => (window as any).__stopSeen())) as Seen;
          const out = process.env.FAST_CHECKS_OUT
            ? path.join(process.env.FAST_CHECKS_OUT, `session-info-flicker-${engine}-${glass}-${width}-${over}`)
            : undefined;
          if (out) await mkdir(out, { recursive: true });
          const pixels = pixelStats(
            frames,
            {
              x: Math.round(panelBox.x) + 2,
              y: Math.round(panelBox.y) + 2,
              width: Math.round(panelBox.width) - 4,
              height: Math.round(panelBox.height) - 4,
            },
            out,
          );
          if (out) await page.screenshot({ path: path.join(out, "end.png") });
          console.log(
            `SESSION-INFO-SCROLL-FLICKER ${JSON.stringify({ engine, glass, width, over, scrollable, ...seen, pixels })}`,
          );
          expect(seen.frames).toBeGreaterThan(60);
          if (over === "panel") expect(seen.scrolledPx, "the panel's body scrolled").toBeGreaterThan(40);
          expect(seen.replaced, "frames the panel's node was gone or replaced").toBe(0);
          expect(seen.slotsReplaced, "section slots drawn anew").toBe(0);
          expect(seen.restShown, "frames a held-back rows box showed in the body's window").toBe(0);
          expect(pixels.blank, "delivered frames with the panel blank").toBe(0);
          expect(pixels.flashes, "delivered frames the panel flashed").toBe(0);
          expect(seen.lookChanges, "frames the panel's look changed").toBe(0);
        } finally {
          await page.close();
        }
      });
});
