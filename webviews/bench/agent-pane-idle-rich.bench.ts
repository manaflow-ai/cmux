// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// What the production agent pane asks for while nobody touches it, on a chat shaped like a coordinator's:
// the ordinary generated session (bench/godFixture.ts "small": 300 turns with edit diffs, shell logs, code blocks,
// a subagent chain, an image), Session Info open, and either
//   running  a turn open with a background subagent, a background shell, a command and an edit in progress, a reply
//            with a code block, and a queued message, but no record arriving; or
//   rest     the same chat with no turn open.
// Each scenario runs twice: Chromium's own 60 Hz, and unthrottled (--disable-frame-rate-limit
// --disable-gpu-vsync), so a requester that scales with the display rate shows. Per phase it prints the renderer's
// main-thread time per second, style recalcs and layouts per second, and every frame, timer and animation by call
// site (bench/stability.ts), mapped back to source files through the build's source maps. The `capture` phase runs
// the page's own `cmux app chat perf` capture (window.cmuxAcpmuxBridge.perfCapture) over the same window, so the
// frames it reports can be set against the frames the page's own code asked for.
//   bun bench/agent-pane-idle-rich.bench.ts [phaseMs=5000]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { godLog } from "./godFixture";
import { sourceMapper } from "./sourceMapper";
import { addStabilityProbe, cpuSession, measureIdle, settledAt } from "./stability";

const PHASE_MS = Number(process.argv[2] ?? 5000);
const webviews = path.resolve(import.meta.dir, "..");
const CHAT = "0190a000-0000-7000-8000-0000000c0de1";
const LATEST = "Latest: the coordinator has three lanes out";

type Params = { sessionId?: string; tag?: string; subagents?: unknown[] };
const update = (body: Record<string, unknown>, { sessionId = CHAT, tag, subagents }: Params = {}) => ({
  method: "session/update",
  params: {
    sessionId,
    update: body,
    ...((tag || subagents) && {
      _meta: { acpmux: { ...(tag && { subagent: tag }), ...(subagents && { subagents }) } },
    }),
  },
});
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];

const REPLY = [
  `${LATEST}. The frame budget reads:`,
  "",
  "```ts",
  "export function settle(chat: Element) {",
  "  const budget = shareFrameBudget(chat);",
  "  budget.poke();",
  "  return () => budget.dispose();",
  "}",
  "```",
  "",
  "| lane | state |",
  "| --- | --- |",
  "| idle-loop | measuring |",
  "| tail | merged |",
].join("\n");

function chat(running: boolean) {
  const log = godLog("small");
  const steps: { dir: string; kind: string; msg: Record<string, unknown> }[] = log.events.map((event) => ({
    dir: event.dir,
    kind: event.kind,
    msg: event.msg as Record<string, unknown>,
  }));
  const HELPER_CALL = "toolu_coord_helper";
  const HELPER = `${CHAT}/${HELPER_CALL}`;
  const tail: Step[] = [
    ["mux", "user_message", { text: "Coordinate the lanes and report" }],
    ["mux", "turn_started", {}],
    say(REPLY),
    [
      "in",
      "subagent_spawned",
      update(
        { sessionUpdate: "subagent_spawned", name: "Lane review", background: true },
        {
          subagents: [
            {
              id: HELPER,
              parent: null,
              name: "Lane review",
              kind: "general-purpose",
              state: "running",
              background: true,
            },
          ],
        },
      ),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: HELPER_CALL,
        title: "Agent: Lane review",
        kind: "think",
        status: "in_progress",
        rawInput: { description: "Lane review", prompt: "Review the lanes", run_in_background: true },
      }),
    ],
    [
      "in",
      "tool_call",
      update(
        {
          sessionUpdate: "tool_call",
          toolCallId: "helper-grep",
          title: "grep -rn frameBudget src",
          kind: "execute",
          status: "in_progress",
          rawInput: { command: "grep -rn frameBudget src" },
        },
        { sessionId: HELPER, tag: HELPER },
      ),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "bg-watch",
        title: "cargo watch -x test",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: "cargo watch -x test", run_in_background: true },
        _meta: { claude: { tool: "Bash" } },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "bg-watch",
        status: "completed",
        content: [
          { type: "content", content: { type: "text", text: "Command running in background with ID: bg-watch" } },
        ],
      }),
    ],
    [
      "in",
      "background_task_update",
      update({
        sessionUpdate: "background_task_update",
        taskId: "task-bg-watch",
        toolCallId: "bg-watch",
        command: "cargo watch -x test",
        state: "running",
      }),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "edit-1",
        title: "Edit src/frameBudget.ts",
        kind: "edit",
        status: "in_progress",
        rawInput: { file_path: "/mock/project/src/frameBudget.ts", old_string: "left - 1", new_string: "left - 2" },
        content: [
          { type: "diff", path: "/mock/project/src/frameBudget.ts", oldText: "left - 1\n", newText: "left - 2\n" },
        ],
      }),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "run-1",
        title: "bun test test/frame-budget.test.ts",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: "bun test test/frame-budget.test.ts" },
      }),
    ],
  ];
  const finished: Step[] = [["mux", "turn_result", { status: "completed" }]];
  for (const [dir, kind, msg] of [...tail, ...(running ? [] : finished)]) steps.push({ dir, kind, msg });
  const start = log.events.at(-1)!.at + 60_000;
  const events = steps.map((step, index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: index < log.events.length ? log.events[index]!.at : start + (index - log.events.length) * 500,
    ...step,
  }));
  const at = events.at(-1)!.at;
  const session = {
    ...log.summary,
    sessionId: CHAT,
    title: "Coordinator",
    family: "claude",
    status: running ? "running" : "ready",
    ...(running
      ? {
          turn: { turnId: "turn-run", promptId: "p-run", startedAt: start, prompt: "Coordinate the lanes and report" },
          queue: [{ promptId: "q1", prompt: "Then rebase the tail lane" }],
        }
      : {}),
    turnCount: events.filter((event) => event.kind === "user_message").length,
    updatedAt: at,
    lastSeq: events.length,
  };
  return { events, session };
}

const chats = { running: chat(true), rest: chat(false) };
let current = chats.running;

const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  const lastSeq = current.events.at(-1)?.seq ?? 0;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [current.session] };
    case "_acpmux/attach": {
      const { page, hasMore } = newestPage(current.events, {
        limit: Number(params.limit ?? 400),
        maxBytes: params.maxBytes,
      });
      return { session: current.session, lastSeq, events: page, hasMore };
    }
    case "_acpmux/events": {
      const after = Number(params.afterSeq ?? 0);
      const before = Number(params.beforeSeq ?? Number.POSITIVE_INFINITY);
      const limit = Number(params.limit ?? 400);
      const picked = current.events.filter((event) => event.seq > after && event.seq < before);
      const events = params.beforeSeq !== undefined ? picked.slice(-limit) : picked.slice(0, limit);
      return { events, hasMore: picked.length > events.length, lastSeq };
    }
    default:
      return null;
  }
};

const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of [...releases].reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};

async function metrics(cdp: CDPSession) {
  const { metrics: list } = (await cdp.send("Performance.getMetrics")) as {
    metrics: { name: string; value: number }[];
  };
  return Object.fromEntries(list.map((metric) => [metric.name, metric.value]));
}

process.once("SIGINT", () => void release().then(() => process.exit(130)));
try {
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
      },
    },
  });
  releases.push(() => daemon.stop(true));
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "agent-pane-idle-rich-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, sourcemap: true },
    logLevel: "error",
  });
  const mapper = sourceMapper(out);
  const mapSites = (site: string) =>
    site.replace(/https?:\/\/127\.0\.0\.1:\d+\/assets\/([^:/)\s]+\.js):(\d+):(\d+)/g, (_, file, line, column) =>
      mapper(file, Number(line) - 1, Number(column) - 1),
    );
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${CHAT}`;

  const rates: { name: string; args: string[] }[] = [
    { name: "60hz", args: [] },
    { name: "unthrottled", args: ["--disable-frame-rate-limit", "--disable-gpu-vsync"] },
  ];
  console.log(`agent-pane-idle-rich: ${chats.running.events.length} records, ${PHASE_MS / 1000} s a phase`);
  for (const rate of rates) {
    const browser = await chromium.launch({ headless: true, args: rate.args });
    try {
      for (const scenario of ["running", "rest"] as const) {
        current = chats[scenario];
        const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
        try {
          await addStabilityProbe(context, { boxes: false });
          const page = await context.newPage();
          const cdp = (await cpuSession(page, true))!;
          await page.goto(url);
          await page.waitForFunction((text) => document.body.textContent?.includes(text), LATEST, {
            timeout: 120_000,
            polling: 100,
          });
          const toggle = page.locator("button.acpmux-session-info-toggle").first();
          const info = (await toggle.count()) > 0 && (await toggle.isVisible());
          if (info) await toggle.click();
          await page.waitForTimeout(4000);
          await settledAt(page);
          const present = await page.evaluate(() => ({
            sessionInfo: Boolean(document.querySelector("[class*=session-info]")),
            minimap: Boolean(document.querySelector("[class*=minimap]")),
            tray: Boolean(document.querySelector("[class*=tray]")),
            codeBlocks: document.querySelectorAll("pre").length,
            rows: document.querySelectorAll("[data-row-id]").length,
            spinners: document.querySelectorAll(".cv-spinner").length,
            motion: document.querySelector("[data-chat-motion]")?.getAttribute("data-chat-motion") ?? null,
          }));
          console.log(`\n== ${rate.name} ${scenario} (session info clicked: ${info}) ${JSON.stringify(present)}`);
          for (const phase of ["idle", "capture"] as const) {
            const before = await metrics(cdp);
            const capture =
              phase === "capture"
                ? page.evaluate(
                    (seconds) =>
                      (
                        window as unknown as {
                          cmuxAcpmuxBridge?: { perfCapture?(o: { seconds: number }): Promise<Record<string, unknown>> };
                        }
                      ).cmuxAcpmuxBridge?.perfCapture?.({ seconds }) ?? null,
                    PHASE_MS / 1000,
                  )
                : null;
            const [quiet] = await measureIdle([{ page, cdp }], PHASE_MS);
            const report = (await capture) as { frames?: { count?: number; interval_p50_ms?: number } } | null;
            const after = await metrics(cdp);
            const seconds = PHASE_MS / 1000;
            const per = (name: string) => (((after[name] ?? 0) - (before[name] ?? 0)) / seconds).toFixed(1);
            console.log(
              `-- ${phase}: renderer ${((quiet!.cpuMs ?? 0) / seconds).toFixed(1)} ms/s, recalc ${per("RecalcStyleCount")}/s, ` +
                `layout ${per("LayoutCount")}/s, frames ${(quiet!.frames / seconds).toFixed(1)}/s, timeouts ${(quiet!.timeouts / seconds).toFixed(1)}/s, ` +
                `intervals ${(quiet!.intervals / seconds).toFixed(1)}/s, running animations ${quiet!.animations}` +
                (report ? `, chat perf frames ${report.frames?.count} (p50 ${report.frames?.interval_p50_ms} ms)` : ""),
            );
            for (const source of quiet!.sources.slice(0, 25)) console.log(`   ${mapSites(source)}`);
            // What `cmux app chat perf` now reports as the page's frame owners (frameOwners.ts).
            const owners = (report as { owners?: Record<string, unknown> } | null)?.owners as
              | { page_frames: number; [kind: string]: unknown }
              | null
              | undefined;
            if (report) {
              console.log(`   chat perf owners: page asked in ${owners?.page_frames ?? "(none reported)"} frames`);
              for (const kind of ["frames", "timers", "animate"])
                for (const site of (
                  (owners?.[kind] as { at: string; file: string | null; per_s: number }[]) ?? []
                ).slice(0, 8))
                  console.log(
                    `     ${kind} ${site.per_s}/s ${site.file ?? ""} ${site.at.replace(/(assets\/[^:\s]+\.js):(\d+):(\d+)/, (_, file, line, column) => mapper(file.slice(7), Number(line) - 1, Number(column) - 1))}`,
                  );
              for (const animation of (owners?.animations as unknown[]) ?? [])
                console.log(`     animation ${JSON.stringify(animation)}`);
            }
          }
          await dumpAnimations(page);
        } finally {
          await context.close();
        }
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await release();
}

/// Every animation at rest: its name, target, iterations and whether its target is drawn.
async function dumpAnimations(page: Page) {
  const list = await page.evaluate(() =>
    (document.getAnimations?.() ?? []).map((animation) => {
      const effect = animation.effect as KeyframeEffect | null;
      const target = effect?.target as Element | null;
      const timing = effect?.getComputedTiming?.();
      return {
        name:
          (animation as CSSAnimation).animationName ??
          (animation as CSSTransition).transitionProperty ??
          (animation.id || animation.constructor.name),
        target: target ? `${target.tagName.toLowerCase()}.${[...target.classList].slice(0, 3).join(".")}` : "?",
        state: animation.playState,
        iterations: timing?.iterations ?? null,
        visible: target?.checkVisibility?.() ?? null,
      };
    }),
  );
  console.log(`   animations at rest: ${list.length}`);
  for (const item of list.slice(0, 20)) console.log(`   ${JSON.stringify(item)}`);
}
