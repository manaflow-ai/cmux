import type {
  CreateConversationRequest,
  CreateConversationResponse,
  Participant,
} from "@mux/protocol";
import { LINK_HEADER } from "./account.ts";
import { authenticate } from "./auth.ts";
import { VIEWER_HEADER } from "./conversation.ts";
import { account, conversation, mux, type Env } from "./env.ts";

export { AccountDO } from "./account.ts";
export { ConversationDO } from "./conversation.ts";
export { MuxApi } from "./mux-api.ts";
export { MuxDO } from "./mux.ts";

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/")) return new Response("not found", { status: 404 });

    // Links authenticate with their own token: mlk_<account id, base64url>.<secret>
    if (url.pathname === "/api/link/ws") {
      const token =
        url.searchParams.get("token") ??
        request.headers.get("authorization")?.replace(/^Bearer /, "") ??
        "";
      const parsed = parseLinkToken(token);
      if (!parsed || !(await account(env, parsed.accountId).verifyLinkSecret(parsed.secret))) {
        return json({ error: "unauthorized" }, 401);
      }
      const headers = new Headers(request.headers);
      headers.set(LINK_HEADER, "1");
      return account(env, parsed.accountId).fetch(new Request(request, { headers }));
    }

    // Public: what the web app needs to sign in.
    if (url.pathname === "/api/auth/config") {
      return json({
        stackProjectId: env.MUX_STACK_PROJECT_ID ?? null,
        stackPublishableClientKey: env.MUX_STACK_PUBLISHABLE_CLIENT_KEY ?? null,
        devAuth: env.MUX_DEV_AUTH === "1",
      });
    }

    const viewer = await authenticate(request, env);
    if (!viewer) return json({ error: "unauthorized" }, 401);
    const home = account(env, viewer.id);
    const defaultMuxId = await home.signIn(viewer);

    if (url.pathname === "/api/me" && request.method === "GET") return json(viewer);

    if (url.pathname === "/api/link/token" && request.method === "POST") {
      const secret = await home.mintLinkSecret();
      return json({ token: `mlk_${base64url(viewer.id)}.${secret}` }, 201);
    }

    if (url.pathname === "/api/machines" && request.method === "GET")
      return json(await home.listMachines());

    if (url.pathname === "/api/conversations" && request.method === "GET") {
      return json(await home.listConversations());
    }

    if (url.pathname === "/api/conversations" && request.method === "POST") {
      const body = (await request.json().catch(() => ({}))) as CreateConversationRequest;
      const muxIds = body.muxIds?.length ? body.muxIds : [defaultMuxId];
      const muxes = await Promise.all(
        muxIds.map((id) => mux(env, id).ensure(id, "mux", viewer.id)),
      );
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

function base64url(text: string): string {
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function parseLinkToken(token: string): { accountId: string; secret: string } | undefined {
  const match = token.match(/^mlk_([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]{20,})$/);
  if (!match) return undefined;
  try {
    return { accountId: atob(match[1].replace(/-/g, "+").replace(/_/g, "/")), secret: match[2] };
  } catch {
    return undefined;
  }
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status });
}
