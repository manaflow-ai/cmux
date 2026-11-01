// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A stand-in acpmux daemon and the pane's dev entry for the agent-chat papercut tests (Leo
// 2026-10-19): one chat of `turns` finished turns, and optionally a last turn still running two
// commands. Real Chromium from Playwright.
import path from "node:path";
import type { Browser, Page } from "playwright";
import type { PluginOption } from "vite";
import { installPaintedFrames } from "./paintedFrames";
import { warmViteServer } from "./warmDevServer";

export const PAPERCUT_CHAT = "0190a000-0000-7000-8000-00000000fc01";
const START = Date.UTC(2026, 9, 19, 9, 0, 0);

const update = (update: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update },
});

export type PapercutStep = [dir: string, kind: string, msg: Record<string, unknown>, at?: number];
type Step = PapercutStep;

/// `extra` steps follow the chat's last turn (inside the running turn when `running`); `lead` steps
/// come first, before the first turn; `session` adds to or replaces the chat's summary fields (a
/// queue, say).
export function papercutEvents({
  turns,
  running,
  extra = [],
  lead = [],
  session: fields = {},
}: {
  turns: number;
  running: boolean;
  extra?: Step[];
  lead?: Step[];
  session?: Record<string, unknown>;
}) {
  const steps: Step[] = [];
  let clock = START;
  for (const [dir, kind, msg, at] of lead) steps.push([dir, kind, msg, at ?? clock]);
  for (let n = 1; n <= turns; n++) {
    steps.push(["mux", "user_message", { text: `Question ${n}` }, clock]);
    steps.push(["mux", "turn_started", {}, clock]);
    clock += 2000;
    steps.push([
      "in",
      "agent_message_chunk",
      update({
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: `Answer ${n}: the checks on the merged head are green.` },
      }),
      clock,
    ]);
    steps.push(["mux", "turn_result", { status: "completed" }, clock]);
    clock += 1000;
  }
  if (running) {
    steps.push(["mux", "user_message", { text: "Run the checks", promptId: "p-run", turnId: "turn-run" }, clock]);
    steps.push(["mux", "turn_started", {}, clock]);
    for (const id of ["r1", "r2"]) {
      const command = `bun test ${id}`;
      steps.push([
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
        clock,
      ]);
    }
  }
  for (const [dir, kind, msg, at] of extra) steps.push([dir, kind, msg, at ?? clock]);
  const events = steps.map(([dir, kind, msg, at], index) => ({
    sessionId: PAPERCUT_CHAT,
    seq: index + 1,
    at: at ?? START,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: PAPERCUT_CHAT,
    cwd: "/home/dev/cmux",
    title: "Papercuts",
    harness: "claude",
    family: "claude",
    status: running ? "running" : "ready",
    ...(running ? { turn: { turnId: "turn-run", promptId: "p-run", startedAt: clock, prompt: "Run the checks" } } : {}),
    turnCount: turns + (running ? 1 : 0),
    updatedAt: clock,
    lastSeq: events.length,
    ...fields,
  };
  return { events, session };
}

/// Starts the stand-in daemon and the dev server; returns `open`, `close`, `drop` and `methods`. `open` waits
/// for the last answer, or for `ready` (a selector) when the chat's end shows something else;
/// `methods` lists every method the pages sent the daemon, in order (a stop is `session/cancel`);
/// `drop` closes every page's socket, as an acpmux restart does, and the pages connect again.
export async function papercutPane(
  browser: () => Browser,
  options: {
    turns: number;
    running: boolean;
    extra?: PapercutStep[];
    lead?: PapercutStep[];
    session?: Record<string, unknown>;
    ready?: string;
    /// Attach sends only the newest `attachPage` records and pages older ones in through
    /// `_acpmux/events` (`beforeSeq`, `limit`), as acpmux does for a long chat. Unset, attach sends all.
    attachPage?: number;
    /// Additional chats reuse these fixture events with their own identity and folder.
    otherSessions?: Array<{ sessionId: string; cwd: string }>;
    /// Test-only Vite plugins, kept optional so existing papercut lanes stay unchanged.
    vitePlugins?: PluginOption[];
  },
) {
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  const { events, session } = papercutEvents(options);
  const methods: string[] = [];
  const sockets = new Set<{ close(code?: number, reason?: string): void }>();
  const sessions = [session, ...(options.otherSessions ?? []).map((other) => ({ ...session, ...other }))];
  const answer = (method: string, params?: Record<string, any>): unknown => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions };
      case "_acpmux/attach": {
        const selected = sessions.find((one) => one.sessionId === params?.sessionId) ?? session;
        const from = options.attachPage ? Math.max(0, events.length - options.attachPage) : 0;
        return {
          session: selected,
          lastSeq: events.length,
          events: events.slice(from).map((event) => ({ ...event, sessionId: selected.sessionId })),
          hasMore: from > 0,
        };
      }
      case "_acpmux/events": {
        const before = typeof params?.beforeSeq === "number" ? params.beforeSeq : undefined;
        if (!options.attachPage || before === undefined) return { events: [], hasMore: false, lastSeq: events.length };
        const end = Math.max(0, before - 1);
        const start = Math.max(0, end - Math.min(options.attachPage, Number(params?.limit) || options.attachPage));
        return { events: events.slice(start, end), hasMore: start > 0, lastSeq: events.length };
      }
      default:
        return null;
    }
  };
  /// Every `session/prompt` the page sent, with its params (`_meta.acpmux.promptId`).
  const prompts: Record<string, any>[] = [];
  let socket: { send(data: string): void; close(): void } | undefined;
  /// An acpmux record, appended to the log (a later attach replays it) and sent to the attached page.
  const record = (kind: string, msg: Record<string, unknown>, dir = "mux") => {
    const event = { sessionId: PAPERCUT_CHAT, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    (session as { lastSeq: number }).lastSeq = event.seq;
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };
  /// The connection drops (acpmux restarted): the page connects again and reads the log again.
  const drop = () => {
    for (const socket of sockets) socket.close(1012, "restart");
  };
  /// Waiters for a method's next send: `sent(method, after)` settles once the pages have sent `method`
  /// more than `after` times (an event, not a poll).
  const waiters: { method: string; after: number; done: () => void }[] = [];
  const count = (method: string) => methods.filter((sent) => sent === method).length;
  const sent = (method: string, after: number) =>
    count(method) > after ? Promise.resolve() : new Promise<void>((done) => void waiters.push({ method, after, done }));
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open(ws) {
        sockets.add(ws);
      },
      close(ws) {
        sockets.delete(ws);
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
        methods.push(message.method);
        for (const waiter of waiters.filter((one) => one.method === message.method && count(one.method) > one.after)) {
          waiters.splice(waiters.indexOf(waiter), 1);
          waiter.done();
        }
        socket = ws;
        if (message.method === "session/prompt") prompts.push(message.params ?? {});
        if (message.id !== undefined)
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
      },
    },
  });
  const vite = await createServer({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
    plugins: options.vitePlugins,
  });
  await vite.listen();
  await warmViteServer(vite, "/");
  /// `prepare` runs before the page loads (a test's stand-in for the App's actions, say). `scale` and
  /// `colorScheme` are for stills: a 2x page, light or dark.
  const open = async (
    viewport: { width: number; height: number; scale?: number; colorScheme?: "light" | "dark" } = {
      width: 900,
      height: 700,
    },
    prepare?: (page: Page) => Promise<void>,
  ): Promise<Page> => {
    const { scale, colorScheme, ...size } = viewport;
    const page = await browser().newPage({ viewport: size, deviceScaleFactor: scale, colorScheme });
    await installPaintedFrames(page);
    await prepare?.(page);
    const { port } = vite.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon.port}/`;
    await page.goto(
      `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${PAPERCUT_CHAT}`,
    );
    await (
      options.ready ? page.locator(options.ready).first() : page.getByText(`Answer ${options.turns}:`, { exact: false })
    ).waitFor({ timeout: 120_000 });
    // Rows place by their drawn heights a frame after they mount: wait until no animation runs and
    // the transcript has held its scroll position over three painted frames.
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      for (let tries = 0; tries < 20; tries++) {
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await new Promise<void>((resolve) => {
          let last = -1;
          let still = 0;
          window.cmuxAfterPaint(() => {
            const top = scroller?.scrollTop ?? 0;
            still = top === last ? still + 1 : 0;
            last = top;
            if (still < 2) return true;
            resolve();
            return false;
          });
        });
        if (finite().every((animation) => animation.playState !== "running")) return;
      }
    });
    return page;
  };
  const close = async () => {
    await vite.close();
    await daemon.stop(true);
  };
  return { open, close, methods, prompts, record, drop, sent };
}

/// Settings > Agent Chat > Session Info: Push always (or back to the default), as the host's `display`
/// event sets it (chatDisplay.ts). By default Session Info floats and never takes a column.
export async function sessionInfoPushAlways(page: Page, on = true) {
  await page.evaluate(async (on) => {
    // The pane's dev server serves src/agent-session/acpmux at its root (vite.config.acpmux-pane.mjs),
    // so this is the module the page already loaded.
    const url = "/chatDisplay.ts";
    const display = (await import(/* @vite-ignore */ url)) as { setChatDisplay(value: unknown): void };
    display.setChatDisplay({ "agentPane.display.inspector.placement": on ? "push" : "overlay" });
  }, on);
}
