// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A stand-in acpmux daemon and the pane's dev entry for the agent-chat papercut tests (Leo
// 2026-10-19): one chat of `turns` finished turns, and optionally a last turn still running two
// commands. Real Chromium from Playwright.
import path from "node:path";
import type { Browser, Page } from "playwright";
import { warmViteServer } from "./warmDevServer";

export const PAPERCUT_CHAT = "0190a000-0000-7000-8000-00000000fc01";
const START = Date.UTC(2026, 9, 19, 9, 0, 0);

const update = (update: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update },
});

type Step = [dir: string, kind: string, msg: Record<string, unknown>, at?: number];

export function papercutEvents({ turns, running }: { turns: number; running: boolean }) {
  const steps: Step[] = [];
  let clock = START;
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
  };
  return { events, session };
}

/// Starts the stand-in daemon and the dev server; returns `open` and `close`.
export async function papercutPane(browser: () => Browser, options: { turns: number; running: boolean }) {
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  const { events, session } = papercutEvents(options);
  const answer = (method: string): unknown => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  };
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string };
        if (message.id !== undefined)
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
      },
    },
  });
  const vite = await createServer({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  await warmViteServer(vite, "/");
  const open = async (viewport = { width: 900, height: 700 }): Promise<Page> => {
    const page = await browser().newPage({ viewport });
    const { port } = vite.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon.port}/`;
    await page.goto(
      `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${PAPERCUT_CHAT}`,
    );
    await page.getByText(`Answer ${options.turns}:`, { exact: false }).waitFor({ timeout: 120_000 });
    // Rows place by their drawn heights a frame after they mount.
    await page.waitForTimeout(500);
    return page;
  };
  const close = async () => {
    await vite.close();
    await daemon.stop(true);
  };
  return { open, close };
}
