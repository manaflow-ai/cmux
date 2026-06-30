import { json, randomSessionCode, type SessionCreateResponse } from "./protocol";

interface CollaborationSessionStub {
  create(sessionCode: string): Promise<SessionCreateResponse>;
  fetch(request: Request): Promise<Response>;
}

interface CollaborationSessionNamespace {
  idFromName(name: string): unknown;
  get(id: unknown): CollaborationSessionStub;
}

export interface CollaborationWorkerEnv {
  COLLABORATION_SESSIONS: CollaborationSessionNamespace;
}

export async function collaborationFetch(request: Request, env: CollaborationWorkerEnv): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === "/healthz") {
    return json({ ok: true, service: "cmux-collaboration" });
  }

  if (url.pathname === "/v1/collaboration/sessions" && request.method === "POST") {
    const sessionCode = randomSessionCode();
    const stub = env.COLLABORATION_SESSIONS.get(env.COLLABORATION_SESSIONS.idFromName(sessionCode));
    return json(await stub.create(sessionCode), 201);
  }

  const match = url.pathname.match(/^\/v1\/collaboration\/sessions\/([A-Z0-9-]+)\/connect$/);
  if (match && request.method === "GET") {
    const sessionCode = match[1];
    const stub = env.COLLABORATION_SESSIONS.get(env.COLLABORATION_SESSIONS.idFromName(sessionCode));
    return stub.fetch(request);
  }

  return json({ error: "not_found" }, 404);
}
