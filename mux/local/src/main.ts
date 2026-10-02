import { hostname, userInfo } from "node:os";
import { join, normalize } from "node:path";
import { AcpmuxClient } from "@mux/acpmux";
import { messageText } from "@mux/brain";
import { parseClientFrame, type AccountFrame, type ServerFrame, type Viewer } from "@mux/protocol";
import { lastReply } from "@mux/cli/agents";
import { serveRelay } from "@mux/cli/cmux-relay";
import { muxPaths } from "@mux/cli/paths";
import { Supervisor } from "@mux/cli/supervisor";
import { claimSupervisor } from "@mux/cli/up";
import { hostAllowed, originAllowed } from "./guard.ts";
import { MUX_CONVERSATION_ID, MuxView, type AcpmuxEvent } from "./mux-view.ts";

// Home's server: a live Messages view of the one `mux` acpmux session.
// Start it from a terminal of the cmux app the mux should control: it runs
// `mux up` with that terminal's environment, which also starts the cmux relay.

const port = Number(process.env.MUX_LOCAL_PORT ?? 47820);
const dist = normalize(
  process.env.MUX_WEB_DIST ?? new URL("../../apps/web/dist/", import.meta.url).pathname,
);
const muxCli = normalize(new URL("../../cli/src/main.ts", import.meta.url).pathname);
const session = process.env.MUX_SESSION_NAME ?? "mux";
const viewer: Viewer = { id: "local-user", displayName: userInfo().username };
const view = new MuxView(viewer);
const LIST_TOPIC = "conversations";

type SocketData = { conversation: true } | { events: true };

let client: AcpmuxClient | undefined;

const server = Bun.serve<SocketData>({
  hostname: "127.0.0.1",
  port,
  async fetch(request, server) {
    if (!hostAllowed(request, port) || !originAllowed(request, port))
      return new Response("forbidden", { status: 403 });
    const path = new URL(request.url).pathname;
    if (!path.startsWith("/api/")) return serveStatic(path);
    if (path === "/api/auth/config") {
      return Response.json({
        mode: "none",
        stackProjectId: null,
        stackPublishableClientKey: null,
        devAuth: false,
      });
    }
    if (path === "/api/me") return Response.json(viewer);
    if (path === "/api/machines") {
      return Response.json([
        {
          id: hostname(),
          name: hostname(),
          os: "macos",
          online: true,
          lastSeen: new Date().toISOString(),
        },
      ]);
    }
    if (path === "/api/conversations" && request.method === "GET")
      return Response.json([summary()]);
    // Home has one conversation, the mux: "new conversation" opens it.
    if (path === "/api/conversations" && request.method === "POST") {
      return Response.json({ conversation: view.conversation() }, { status: 201 });
    }
    if (path === "/api/events") {
      if (server.upgrade(request, { data: { events: true } })) return undefined;
      return new Response("expected websocket", { status: 426 });
    }
    if (path === `/api/conversations/${MUX_CONVERSATION_ID}`)
      return Response.json(view.conversation());
    if (path === `/api/conversations/${MUX_CONVERSATION_ID}/ws`) {
      if (server.upgrade(request, { data: { conversation: true } })) return undefined;
      return new Response("expected websocket", { status: 426 });
    }
    return Response.json({ error: "not found" }, { status: 404 });
  },
  websocket: {
    open(ws) {
      if ("events" in ws.data) {
        ws.subscribe(LIST_TOPIC);
        return;
      }
      ws.subscribe(MUX_CONVERSATION_ID);
      ws.send(
        JSON.stringify({
          type: "snapshot",
          conversation: view.conversation(),
        } satisfies ServerFrame),
      );
    },
    message(ws, data) {
      if ("events" in ws.data) return;
      const frame = parseClientFrame(
        typeof data === "string" ? data : new TextDecoder().decode(data),
      );
      if (!frame || frame.type !== "send") return;
      const text = frame.parts.map((p) => (p.type === "text" ? p.text : "")).join("\n");
      if (!client) {
        ws.send(
          JSON.stringify({
            type: "error",
            message: "acpmux is not connected",
          } satisfies ServerFrame),
        );
        return;
      }
      // The clientId becomes the acpmux promptId, so the echo replaces the pending bubble.
      void client.prompt(session, text, frame.clientId).catch((error) => {
        publish({ type: "error", message: `mux did not take the message: ${String(error)}` });
      });
    },
    close(ws) {
      ws.unsubscribe("events" in ws.data ? LIST_TOPIC : MUX_CONVERSATION_ID);
    },
  },
});

function summary() {
  const last = view.conversation().messages.at(-1);
  return {
    id: MUX_CONVERSATION_ID,
    title: "mux",
    preview: last ? messageText(last) : "",
    lastAt: last?.sentAt ?? "",
  };
}

function publish(frame: ServerFrame): void {
  server.publish(MUX_CONVERSATION_ID, JSON.stringify(frame));
  if (frame.type === "message")
    server.publish(LIST_TOPIC, JSON.stringify({ type: "conversations" } satisfies AccountFrame));
}

function apply(event: AcpmuxEvent): void {
  const change = view.apply(event);
  if (change.typing !== undefined)
    publish({ type: "typing", participantId: "mux", on: change.typing });
  for (const message of change.messages)
    publish({ type: "message", message, clientId: message.id });
}

/** A live ACP `session/update` in the shape history records it (kind = the update type). */
function fromUpdate(params: Record<string, unknown>): AcpmuxEvent {
  const meta =
    (params._meta as { acpmux?: { seq?: number; at?: number } } | undefined)?.acpmux ?? {};
  const update = (params.update ?? {}) as { sessionUpdate?: string };
  return {
    seq: meta.seq ?? 0,
    at: meta.at ?? Date.now(),
    dir: "in",
    kind: update.sessionUpdate ?? "",
    msg: { params },
  };
}

/** `mux up` without its detached supervisor: the session and its prompt and hooks. */
async function muxUp(): Promise<void> {
  const child = Bun.spawn([process.execPath, muxCli, "up", "--no-supervisor"], {
    stdin: "ignore",
    stdout: "inherit",
    stderr: "inherit",
  });
  if ((await child.exited) !== 0) throw new Error("mux up failed");
}

/**
 * The supervisor and cmux relay, in this process: started from a cmux
 * terminal and long-lived, it keeps that terminal as an ancestor, which is
 * what cmux's control socket admits.
 */
async function superviseInProcess(): Promise<void> {
  const paths = muxPaths();
  claimSupervisor(paths);
  if (process.env.CMUX_SOCKET_PATH) {
    serveRelay(join(paths.home, "state", "cmux.sock"));
    console.log(`mux home: relaying cmux commands to ${process.env.CMUX_SOCKET_PATH}`);
  } else {
    console.log(
      "mux home: no CMUX_SOCKET_PATH; start this server in a cmux terminal so the mux can control cmux",
    );
  }
  for (let backoff = 1_000; ; backoff = Math.min(backoff * 2, 30_000)) {
    try {
      const connection = await AcpmuxClient.connect(undefined, "mux-supervisor");
      const closed = new Promise<void>((resolve) => connection.onClose(resolve));
      await new Supervisor(connection, lastReply, (line) =>
        console.log(`mux supervisor: ${line}`),
      ).start();
      backoff = 1_000;
      await closed;
    } catch (error) {
      console.log(`mux supervisor: ${String(error)}; retrying`);
    }
    await new Promise((resolve) => setTimeout(resolve, backoff));
  }
}

/** Follows the mux session's event log: history first, then live events; reconnects with backoff. */
async function follow(): Promise<void> {
  for (let backoff = 1_000; ; backoff = Math.min(backoff * 2, 30_000)) {
    try {
      const connection = await AcpmuxClient.connect(undefined, "mux-home");
      const closed = new Promise<void>((resolve) => connection.onClose(resolve));
      let sessionId = "";
      connection.onNotification((n) => {
        if (n.params.sessionId !== sessionId) return;
        // acpmux's own records arrive as events; agent output arrives as plain ACP updates.
        if (n.method === "_acpmux/event") apply(n.params as unknown as AcpmuxEvent);
        if (n.method === "session/update") apply(fromUpdate(n.params));
      });
      const attached = await connection.request<{
        session: { sessionId: string };
        events: AcpmuxEvent[];
      }>("_acpmux/attach", { sessionId: session, afterSeq: 0, limit: 100_000 });
      sessionId = attached.session.sessionId;
      for (const event of attached.events) apply(event);
      client = connection;
      backoff = 1_000;
      console.log(`mux home: following ${session} (${attached.events.length} events)`);
      await closed;
      client = undefined;
      console.log("mux home: acpmux connection closed; reconnecting");
    } catch (error) {
      console.log(`mux home: ${String(error)}; retrying`);
    }
    await new Promise((resolve) => setTimeout(resolve, backoff));
  }
}

async function serveStatic(path: string): Promise<Response> {
  const file = normalize(join(dist, path));
  if (file.startsWith(dist) && path !== "/") {
    const asset = Bun.file(file);
    if (await asset.exists()) return new Response(asset);
  }
  const index = Bun.file(join(dist, "index.html"));
  if (await index.exists())
    return new Response(index, { headers: { "content-type": "text/html; charset=utf-8" } });
  return new Response(
    `mux web app not built: run \`vp run -r build\` in mux/ (looked in ${dist})`,
    { status: 503 },
  );
}

console.log(`mux home: http://127.0.0.1:${port}`);
await muxUp();
void superviseInProcess();
void follow();
