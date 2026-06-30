import { expect, test } from "bun:test";
import { collaborationFetch, type CollaborationWorkerEnv } from "../src/handler";

class FakeSessionStub {
  createdSessionCode: string | null = null;
  fetchRequests: Request[] = [];

  async create(sessionCode: string) {
    this.createdSessionCode = sessionCode;
    return {
      sessionID: sessionCode,
      sessionCode,
      token: `token-for-${sessionCode}`,
    };
  }

  async fetch(request: Request) {
    this.fetchRequests.push(request);
    return new Response("routed-to-session", { status: 299 });
  }
}

class FakeSessionNamespace {
  stubs = new Map<string, FakeSessionStub>();

  idFromName(name: string) {
    return name;
  }

  get(id: string) {
    let stub = this.stubs.get(id);
    if (!stub) {
      stub = new FakeSessionStub();
      this.stubs.set(id, stub);
    }
    return stub;
  }
}

test("join route uses session code to reach the created session object", async () => {
  const namespace = new FakeSessionNamespace();
  const env = {
    COLLABORATION_SESSIONS: namespace,
  } satisfies CollaborationWorkerEnv;

  const createResponse = await collaborationFetch(
    new Request("http://relay.test/v1/collaboration/sessions", { method: "POST" }),
    env
  );
  const created = await createResponse.json() as { sessionCode: string; token: string };

  const joinResponse = await collaborationFetch(
    new Request(
      `http://relay.test/v1/collaboration/sessions/${created.sessionCode}/connect?token=${created.token}`,
      { method: "GET" }
    ),
    env
  );

  const stub = namespace.stubs.get(created.sessionCode);
  expect(createResponse.status).toBe(201);
  expect(joinResponse.status).toBe(299);
  expect(stub?.createdSessionCode).toBe(created.sessionCode);
  expect(stub?.fetchRequests).toHaveLength(1);
  expect(new URL(stub?.fetchRequests[0]?.url ?? "").pathname).toBe(
    `/v1/collaboration/sessions/${created.sessionCode}/connect`
  );
});
