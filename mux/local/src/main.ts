import { hostname, homedir, userInfo } from "node:os";
import { join, normalize } from "node:path";
import { mkdirSync } from "node:fs";
import { messageText } from "@mux/brain";
import {
  parseClientFrame,
  type CreateConversationRequest,
  type ID,
  type Participant,
  type ServerFrame,
  type Viewer,
} from "@mux/protocol";
import { acpmuxRunner, firstPrompt, sessionName } from "./agent.ts";
import { hostAllowed, originAllowed } from "./guard.ts";
import { LocalMemory } from "./memory.ts";
import { LocalStore } from "./store.ts";

const port = Number(process.env.MUX_LOCAL_PORT ?? 47820);
const dir = process.env.MUX_LOCAL_DIR ?? join(homedir(), ".cmux", "mux");
const dist = normalize(
  process.env.MUX_WEB_DIST ?? new URL("../../apps/web/dist/", import.meta.url).pathname,
);
mkdirSync(join(dir, "work"), { recursive: true });

const store = new LocalStore(join(dir, "mux.db"));
const memory = new LocalMemory(join(dir, "memory"));
const agent = acpmuxRunner({
  harness: process.env.MUX_LOCAL_HARNESS ?? "claude",
  policy: process.env.MUX_LOCAL_POLICY ?? "approve-all",
  cwd: join(dir, "work"),
});
const viewer: Viewer = { id: "local-user", displayName: userInfo().username };
const me: Participant = { kind: "human", id: viewer.id, displayName: viewer.displayName };
const mux: Participant = { kind: "mux", id: "mux-local", displayName: "mux" };

/** One turn at a time per conversation; acpmux queues too, but replies must post in order. */
const turns = new Map<ID, Promise<void>>();

type SocketData = { conversationId: ID };

const server = Bun.serve<SocketData>({
  hostname: "127.0.0.1",
  port,
  async fetch(request, server) {
    if (!hostAllowed(request, port) || !originAllowed(request, port))
      return new Response("forbidden", { status: 403 });
    const url = new URL(request.url);
    const path = url.pathname;
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
      return Response.json(store.list());
    if (path === "/api/conversations" && request.method === "POST") {
      const body = (await request.json().catch(() => ({}))) as CreateConversationRequest;
      return Response.json(
        { conversation: store.create(body.title?.trim() || "mux", [me, mux]) },
        { status: 201 },
      );
    }
    const match = path.match(/^\/api\/conversations\/([0-9a-f-]{36})(\/ws)?$/);
    if (match) {
      const conversation = store.get(match[1]);
      if (!conversation) return Response.json({ error: "not found" }, { status: 404 });
      if (!match[2]) return Response.json(conversation);
      if (server.upgrade(request, { data: { conversationId: conversation.id } })) return undefined;
      return new Response("expected websocket", { status: 426 });
    }
    return Response.json({ error: "not found" }, { status: 404 });
  },
  websocket: {
    open(ws) {
      ws.subscribe(ws.data.conversationId);
      const conversation = store.get(ws.data.conversationId);
      if (conversation)
        ws.send(JSON.stringify({ type: "snapshot", conversation } satisfies ServerFrame));
    },
    message(ws, data) {
      const frame = parseClientFrame(
        typeof data === "string" ? data : new TextDecoder().decode(data),
      );
      if (!frame)
        return void ws.send(
          JSON.stringify({ type: "error", message: "bad frame" } satisfies ServerFrame),
        );
      const id = ws.data.conversationId;
      if (frame.type === "typing")
        return publish(id, { type: "typing", participantId: viewer.id, on: frame.on });
      const message = store.append(id, viewer.id, frame.parts);
      publish(id, { type: "message", message, clientId: frame.clientId });
      const title = store.get(id)?.title ?? "mux";
      void memory.append(`[${title}] ${viewer.displayName}: ${messageText(message)}`);
      const previous = turns.get(id) ?? Promise.resolve();
      const next = previous.then(() => turn(id, `${viewer.displayName}: ${messageText(message)}`));
      turns.set(id, next);
    },
    close(ws) {
      ws.unsubscribe(ws.data.conversationId);
    },
  },
});

function publish(conversationId: ID, frame: ServerFrame): void {
  server.publish(conversationId, JSON.stringify(frame));
}

async function turn(conversationId: ID, text: string): Promise<void> {
  const conversation = store.get(conversationId);
  if (!conversation) return;
  const session = sessionName(conversationId);
  // The agent got its instructions on this conversation's first turn; acpmux keeps them in its context.
  const first = !conversation.messages.some((m) => m.senderId === mux.id);
  publish(conversationId, { type: "typing", participantId: mux.id, on: true });
  let reply: string;
  try {
    await agent.ensure(session);
    const prompt = first
      ? `${firstPrompt({ memoryDir: memory.dir, memory: memory.tail(), title: conversation.title })}\n\n${text}`
      : text;
    reply = (await agent.send(session, prompt)) || "(no reply)";
  } catch (error) {
    reply = `I could not answer that: ${error instanceof Error ? error.message : String(error)}`;
  }
  publish(conversationId, { type: "typing", participantId: mux.id, on: false });
  const message = store.append(conversationId, mux.id, [{ type: "text", text: reply }]);
  publish(conversationId, { type: "message", message });
  await memory.append(`[${conversation.title}] me: ${reply}`);
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

console.log(`mux local: http://127.0.0.1:${port} (data ${dir})`);
