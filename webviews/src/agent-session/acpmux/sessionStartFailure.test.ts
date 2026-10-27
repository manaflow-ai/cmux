import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = new Map(["window", "document"].map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)]));

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});

afterAll(() => {
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
  dom.window.close();
});

type Request = { method: string; params: Record<string, any> };
type Daemon = { answer(method: string, params: Record<string, any>): Promise<unknown> };

async function startFixture(previous: boolean) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const answer = daemon.answer.bind(daemon);
  const requests: Request[] = [];
  let entered!: (request: Request) => void;
  const requested = new Promise<Request>((resolve) => (entered = resolve));
  let resolveStart!: (value: unknown) => void;
  let rejectStart!: (error: Error) => void;
  const pending = new Promise<unknown>((resolve, reject) => {
    resolveStart = resolve;
    rejectStart = reject;
  });
  let first = true;
  daemon.answer = (method, params) => {
    requests.push({ method, params });
    if (method === "session/new" && first) {
      first = false;
      entered({ method, params });
      return pending;
    }
    return answer(method, params);
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );
  if (!previous) client.leave();
  return { client, requests, requested, resolveStart, rejectStart, answer, previousSession: mockHost.sessionId };
}

for (const previous of [false, true]) {
  for (const preflight of [false, true]) {
    for (const failure of ["rejected", "empty"] as const) {
      test(`a ${failure} selected harness start never sends to ${previous ? "the previous chat" : "a default harness"}${preflight ? " after the app's start preflight" : ""}`, async () => {
        const fixture = await startFixture(previous);
        const { client, requests } = fixture;
        try {
          const start = client.create("claude", undefined, undefined, true);
          await fixture.requested;
          const send = preflight
            ? client.ensureSession().then(() => client.send("use the selected harness"))
            : client.send("use the selected harness");
          const settled = Promise.allSettled([start, send]);
          if (failure === "rejected") fixture.rejectStart(new Error("selected harness failed to start"));
          else fixture.resolveStart({});
          const [created, sent] = await settled;
          expect(created.status).toBe(failure === "rejected" ? "rejected" : "fulfilled");
          expect(sent.status).toBe("rejected");
          expect(requests.filter((request) => request.method === "session/new")).toHaveLength(1);
          expect(requests.filter((request) => request.method === "session/prompt")).toEqual([]);
          expect(client.shownSession()?.sessionId).toBe(previous ? fixture.previousSession : undefined);
        } finally {
          client.close();
        }
      });
    }
  }
}

test("a send waiting for a selected harness starts only in that new chat", async () => {
  const fixture = await startFixture(true);
  const { client, requests } = fixture;
  try {
    const start = client.create("claude", undefined, undefined, true);
    const requested = await fixture.requested;
    const send = client.send("use the selected harness");
    expect(requested.params._meta.acpmux.harness).toBe("claude");
    expect(requests.filter((request) => request.method === "session/prompt")).toEqual([]);
    fixture.resolveStart(await fixture.answer(requested.method, requested.params));
    const [session] = await Promise.all([start, send]);
    expect(session).toBeDefined();
    expect(session).not.toBe(fixture.previousSession);
    expect(
      requests.filter((request) => request.method === "session/prompt").map((request) => request.params.sessionId),
    ).toEqual([session]);
  } finally {
    client.close();
  }
});
