import type {
  CreateConversationRequest,
  CreateConversationResponse,
  Participant,
} from "@mux/protocol";
import { authenticate } from "./auth.ts";
import { VIEWER_HEADER } from "./conversation.ts";
import { account, conversation, mux, type Env } from "./env.ts";

export { AccountDO } from "./account.ts";
export { ConversationDO } from "./conversation.ts";
export { MuxDO } from "./mux.ts";

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/")) return new Response("not found", { status: 404 });
    const viewer = await authenticate(request, env);
    if (!viewer) return json({ error: "unauthorized" }, 401);
    const home = account(env, viewer.id);
    const defaultMuxId = await home.signIn(viewer);

    if (url.pathname === "/api/me" && request.method === "GET") return json(viewer);

    if (url.pathname === "/api/conversations" && request.method === "GET") {
      return json(await home.listConversations());
    }

    if (url.pathname === "/api/conversations" && request.method === "POST") {
      const body = (await request.json().catch(() => ({}))) as CreateConversationRequest;
      const muxIds = body.muxIds?.length ? body.muxIds : [defaultMuxId];
      const muxes = await Promise.all(muxIds.map((id) => mux(env, id).ensure(id, "mux")));
      const me: Participant = { kind: "human", id: viewer.id, displayName: viewer.displayName };
      const id = crypto.randomUUID();
      const created = await conversation(env, id).init(id, body.title?.trim() || "mux", [
        me,
        ...muxes,
      ]);
      return json({ conversation: created } satisfies CreateConversationResponse, 201);
    }

    const match = url.pathname.match(/^\/api\/conversations\/([0-9a-f-]{36})(\/ws)?$/);
    if (match) {
      const room = conversation(env, match[1]);
      if (!(await room.isMember(viewer.id))) return json({ error: "not found" }, 404);
      if (match[2]) {
        const headers = new Headers(request.headers);
        headers.set(VIEWER_HEADER, viewer.id);
        return room.fetch(new Request(request, { headers }));
      }
      return json(await room.snapshot());
    }

    return json({ error: "not found" }, 404);
  },
} satisfies ExportedHandler<Env>;

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status });
}
