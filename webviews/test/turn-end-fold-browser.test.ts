// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// Finished runs fold while a turn runs. At its end the whole turn folds under "Worked for",
// leaving only the final answer. Closing the turn resets every disclosure inside it.
// The real agent pane talks to a stand-in acpmux daemon and measures each painted frame.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { pinLiveTurnRuns } from "./support/liveTurnRuns";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("turn-end-fold-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("turn-end-fold-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("turn end fold", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000f1";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/net",
    title: "Flaky retry",
    harness: "claude" as string,
    family: "claude" as string,
    status: "idle",
    turnCount: 1,
    updatedAt: Date.now(),
  };
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  // The chat's earlier turns, so it opens with history above and the view scrolls.
  for (let turn = 0; turn < 6; turn++) {
    record("mux", "user_message", { text: `What does the retry do, part ${turn + 1}?`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `It waits a little longer before each retry and adds a random jitter (part ${turn + 1}).\n\n` +
          "The wait doubles from a quarter second up to the cap, so a flaky network gets time to recover " +
          "while a dead one fails fast enough for the caller to see it.",
      ),
    );
    record("mux", "turn_result", { status: "completed" });
  }
  const opened = events.length;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  type Call = { id: string; title: string; kind: string; command?: string; path?: string };
  const CALLS: Call[] = [
    { id: "t1", title: "git pull -q --ff-only", kind: "execute", command: "git pull -q --ff-only" },
    { id: "t2", title: "Edit src/net/retry.ts", kind: "edit", path: "/home/dev/net/src/net/retry.ts" },
    { id: "t3", title: "bun test test/retry.test.ts", kind: "execute", command: "bun test test/retry.test.ts" },
    {
      id: "t4",
      title: "bun test test/retry.test.ts -t jitter",
      kind: "execute",
      command: "bun test test/retry.test.ts -t jitter",
    },
  ];
  const MORE: Call[] = [
    { id: "t5", title: "Read src/net/backoff.ts", kind: "read", path: "/home/dev/net/src/net/backoff.ts" },
    { id: "t6", title: "bun test test/net", kind: "execute", command: "bun test test/net" },
  ];
  /// After a short aside: before the fix the running turn joined this run and the one above into
  /// one row (turns.ts mergeShortNotes), and the rows the reader had in sight left mid-turn.
  const LAST: Call[] = [
    { id: "t7", title: "bunx tsc --noEmit -p .", kind: "execute", command: "bunx tsc --noEmit -p ." },
    { id: "t8", title: "git status --short", kind: "execute", command: "git status --short" },
  ];
  const started = (call: Call) =>
    update({
      sessionUpdate: "tool_call",
      toolCallId: call.id,
      title: call.title,
      kind: call.kind,
      status: "in_progress",
      ...(call.command && { rawInput: { command: call.command } }),
      ...(call.path && { locations: [{ path: call.path }] }),
      ...(call.kind === "edit" && {
        content: [{ type: "diff", path: call.path, oldText: "const cap = 30;\n", newText: "const cap = 32;\n" }],
      }),
    });
  const finished = (call: Call) =>
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: call.id,
      status: "completed",
      ...(call.kind === "execute" && {
        content: [{ type: "content", content: { type: "text", text: "ok\n" } }],
        rawOutput: { exit_code: 0 },
      }),
    });

  /// The page the turn runs on: each step goes out a painted frame after the one before.
  let runningOn: Page | undefined;
  /// Resolves the turn's end: the test opens its group, then lets the turn end.
  let endTurn: (() => void) | undefined;
  let turnEnded: Promise<void> = Promise.resolve();
  async function run(ws: { send(data: string): void }, params: Record<string, any>, id: number) {
    const send = (event: Event) => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    const frames = async (n = 3) => {
      for (let frame = 0; frame < n; frame++) await runningOn?.evaluate(() => window.cmuxPaintFrame());
    };
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    const ending = new Promise<void>((done) => (endTurn = done));
    send(record("mux", "user_message", { text, promptId: params._meta?.acpmux?.promptId }));
    send(record("mux", "turn_started", {}));
    for (const call of CALLS) {
      send(record("in", "tool_call", started(call)));
      await frames();
      send(record("in", "tool_call_update", finished(call)));
      await frames();
    }
    send(record("in", "agent_message_chunk", chunk("The jitter case fails; checking the backoff next.")));
    await frames();
    for (const call of MORE) {
      send(record("in", "tool_call", started(call)));
      await frames();
      send(record("in", "tool_call_update", finished(call)));
      await frames();
    }
    send(record("in", "agent_message_chunk", chunk("Now the types:")));
    await frames();
    for (const call of LAST) {
      send(record("in", "tool_call", started(call)));
      await frames();
      send(record("in", "tool_call_update", finished(call)));
      await frames();
    }
    send(record("in", "agent_message_chunk", chunk("\n\nFixed: the jitter now stays inside the backoff's cap.")));
    await frames();
    await ending;
    send(record("mux", "turn_result", { status: "completed" }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.method === "session/prompt" && message.id !== undefined) {
            turnEnded = run(ws, message.params ?? {}, message.id);
            return;
          }
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Sample = { prompt: number; answer: number; gap: number; work: number; worked: boolean; folding: boolean };
  /// Runs the turn on a fresh page for `family`: what the running turn drew, then (the reader back
  /// at the bottom, the edits group opened first when `openGroup`) every painted frame of its end.
  async function playTurn(
    family: string,
    openGroup: boolean,
    reducedMotion: "reduce" | "no-preference" = "no-preference",
  ) {
    summary.harness = family;
    summary.family = family;
    // Each chat opens on the same history; the turn before it is gone.
    events.length = opened;
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 }, reducedMotion });
    await installPaintedFrames(page);
    await pinLiveTurnRuns(page);
    runningOn = page;
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("random jitter (part 6)").waitFor();

    // Every painted frame of the running turn: the rows and calls drawn, and any the view showed
    // that left it (a row the virtualizer drops out of view, history above, is not one).
    await page.evaluate(() => {
      const seen = { shown: new Set<string>(), calls: new Set<string>(), left: [] as string[], frames: 0 };
      (window as any).turnEndProbe = seen;
      window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (!scroller) return;
        const view = scroller.getBoundingClientRect();
        const drawn = new Set<string>();
        const shown = new Set<string>();
        // Drawn: laid out with a height (a call inside a closed fold line is not).
        const note = (key: string, node: HTMLElement) => {
          const box = node.getBoundingClientRect();
          if (box.height <= 0) return;
          drawn.add(key);
          if (box.bottom > view.top && box.top < view.bottom) shown.add(key);
        };
        for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]"))
          note(`row ${row.dataset.rowId}`, row);
        for (const call of scroller.querySelectorAll<HTMLElement>("[data-tool-id]"))
          note(`call ${call.dataset.toolId}`, call);
        for (const key of seen.shown) if (!drawn.has(key)) seen.left.push(key);
        seen.shown = shown;
        seen.calls = new Set([...drawn].filter((key) => key.startsWith("call ")).map((key) => key.slice(5)));
        seen.frames += 1;
        return !(window as any).turnEndProbeStop;
      });
    });
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("Fix the flaky retry test");
    await page.keyboard.press("Enter");
    await page.getByText("Fixed: the jitter now stays", { exact: false }).waitFor();
    const live = await page.evaluate(() => {
      (window as any).turnEndProbeStop = true;
      const probe = (window as any).turnEndProbe;
      const runs = [...document.querySelectorAll(".cv-tool.is-run")];
      return {
        calls: [...probe.calls] as string[],
        runs: runs.map((run) => run.getAttribute("aria-expanded")),
      };
    });
    if (openGroup) {
      // The reader opens the first run, then its edits group, while the turn runs.
      await page.locator(".cv-tool.is-run").first().click();
      const edits = page.locator('button[data-tool-group^="group:edits:"]');
      await edits.click();
      expect(await edits.getAttribute("aria-expanded")).toBe("true");
    }
    // Back at the bottom, as a reader following the turn is: they scroll down to the latest row.
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    for (let step = 0; step < 4; step++) {
      await page.mouse.wheel(0, 1_200);
      for (let frame = 0; frame < 6; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    }
    for (let frame = 0; frame < 30; frame++) await page.evaluate(() => window.cmuxPaintFrame());

    // The turn ends: every painted frame for a while, where the prompt and the answer are drawn.
    await page.evaluate(() => {
      const samples: Sample[] = [];
      (window as any).turnEndSamples = samples;
      const started = performance.now();
      window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const view = scroller.getBoundingClientRect();
        const prompt = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].find((row) =>
          row.textContent?.includes("Fix the flaky retry test"),
        );
        const answer = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].find((row) =>
          row.textContent?.includes("Fixed: the jitter now stays"),
        );
        samples.push({
          prompt: prompt ? Math.round(prompt.getBoundingClientRect().top - view.top) : NaN,
          answer: answer ? Math.round(view.bottom - answer.getBoundingClientRect().bottom) : NaN,
          gap: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
          // How much of the folded work is still drawn: the most opaque row showing its first call.
          work: Math.max(
            0,
            ...[...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
              .filter((row) => row.querySelector(".cv-tool.is-run") && row.getBoundingClientRect().height > 0)
              .map((row) => Number(getComputedStyle(row).opacity)),
          ),
          worked: Boolean(scroller.querySelector("button.cv-worked")),
          folding: Boolean(scroller.querySelector("[data-turn-end-folding]")),
        });
        return performance.now() - started < 1_200;
      });
    });
    endTurn!();
    await turnEnded;
    await page.locator("button.cv-worked").first().waitFor();
    for (let frame = 0; frame < 80; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    const samples = (await page.evaluate(() => (window as any).turnEndSamples)) as Sample[];
    return { page, live, samples };
  }

  for (const family of ["claude", "codex"]) {
    test(`${family}: finished runs stay folded while the turn runs`, async () => {
      const { page, live } = await playTurn(family, false);
      expect(live.runs.length).toBeGreaterThan(0);
      expect(live.runs.every((expanded) => expanded === "false")).toBe(true);
      for (const id of ["t1", "t3", "t4", "t5", "t6", "t7", "t8"]) expect(live.calls).not.toContain(id);
      await page.close();
    });

    test(`${family}: at its end the work folds in one motion, the bottom pinned`, async () => {
      const { page, samples } = await playTurn(family, false);
      const from = samples.findIndex((sample) => sample.worked);
      expect(from).toBeGreaterThan(0);
      const before = samples[from - 1]!;
      const after = samples.at(-1)!;
      const folding = samples.slice(from - 1);
      console.log(
        `TURN_END_FOLD ${JSON.stringify(folding.map((sample) => [sample.prompt, sample.answer, sample.gap, sample.work]))}`,
      );
      // The prompt comes down to the folded line over several frames, not in one step.
      expect(after.prompt - before.prompt).toBeGreaterThan(40);
      const between = folding.filter(
        (sample) => sample.prompt > before.prompt + 2 && sample.prompt < after.prompt - 2,
      ).length;
      expect(between).toBeGreaterThanOrEqual(3);
      const steps = folding.slice(1).map((sample, index) => sample.prompt - folding[index]!.prompt);
      expect(Math.max(...steps)).toBeLessThan((after.prompt - before.prompt) * 0.75);
      // The work the fold takes away fades over several frames where it was, never gone in one.
      expect(samples[from]!.work).toBeGreaterThan(0.5);
      expect(folding.filter((sample) => sample.work > 0.05 && sample.work < 0.95).length).toBeGreaterThanOrEqual(3);
      expect(after.work).toBe(0);
      // The bottom stays pinned on every frame of the fold: the view stays at its end.
      for (const sample of folding) expect(sample.gap).toBeLessThanOrEqual(2);
      // The answer comes to its place too, never in one step (the turn's edits card and its footer
      // come in under it).
      const answerMove = after.answer - before.answer;
      const answerSteps = folding.slice(1).map((sample, index) => Math.abs(sample.answer - folding[index]!.answer));
      if (Math.abs(answerMove) > 8) expect(Math.max(...answerSteps)).toBeLessThan(Math.abs(answerMove) * 0.75);
      // Closed: the folded turn's line.
      expect(await page.locator("button.cv-worked").first().getAttribute("aria-expanded")).toBe("false");
      await page.close();
    });

    test(`${family}: with Reduce Motion the turn's end folds at once, with nothing left over`, async () => {
      const { page, samples } = await playTurn(family, false, "reduce");
      const from = samples.findIndex((sample) => sample.worked);
      expect(from).toBeGreaterThan(0);
      expect(samples.some((sample) => sample.folding)).toBe(false);
      // The first frame of the ended turn is its last: the work is gone and the prompt in its place.
      expect(samples[from]!.work).toBe(0);
      expect(samples[from]!.prompt).toBe(samples.at(-1)!.prompt);
      await page.close();
    });

    test(`${family}: ending the turn resets the run and group the reader opened`, async () => {
      const { page } = await playTurn(family, true);
      await page.locator("button.cv-worked").first().click();
      const run = page.locator(".cv-tool.is-run").first();
      expect(await run.getAttribute("aria-expanded")).toBe("false");
      await run.click();
      const again = page.locator('button[data-tool-group^="group:edits:"]');
      await again.waitFor();
      expect(await again.getAttribute("aria-expanded")).toBe("false");
      await page.close();
    });
  }
});
