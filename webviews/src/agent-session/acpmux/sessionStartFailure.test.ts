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

async function startFixture(previous: boolean, remote = false) {
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
  daemon.answer = async (method, params) => {
    requests.push({ method, params });
    if (method === "session/new" && first) {
      first = false;
      entered({ method, params });
      return pending;
    }
    if (method === "initialize" && remote) {
      const result = (await answer(method, params)) as { _meta: { acpmux: Record<string, unknown> } };
      return {
        ...result,
        _meta: { ...result._meta, acpmux: { ...result._meta.acpmux, origin: "remote", extensions: [] } },
      };
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
  return {
    client,
    daemon,
    requests,
    requested,
    resolveStart,
    rejectStart,
    answer,
    previousSession: mockHost.sessionId,
  };
}

test("a canceled start's late Trust refusal cannot replace the newer start's retry", async () => {
  const fixture = await startFixture(false);
  const { client, daemon } = fixture;
  const answer = daemon.answer.bind(daemon);
  let trusted = false;
  const refusal = (cwd: string) =>
    Object.assign(new Error("Trust pending"), {
      data: { reason: "trust.pending", cwd },
    });
  daemon.answer = async (method, params) => {
    if (method === "session/new" && params.cwd === "/tmp/newer-start" && !trusted) throw refusal("/tmp/newer-start");
    return answer(method, params);
  };
  const routed: string[] = [];
  let retry: (() => void) | undefined;
  let asked!: () => void;
  const newerAsked = new Promise<void>((resolve) => (asked = resolve));
  client.onTrustRefused = (error, again) => {
    routed.push(error.cwd ?? "");
    retry = again;
    asked();
  };
  try {
    const oldStart = client.create("claude", "/tmp/older-start", undefined, false, undefined, true);
    await fixture.requested;
    const newStart = client.create("claude", "/tmp/newer-start", undefined, false, undefined, true);
    await newerAsked;
    expect(await oldStart).toBeUndefined();
    fixture.rejectStart(refusal("/tmp/older-start"));
    // Mock replies and the client's rejection chain use microtasks; drain them for one turn.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(routed).toEqual(["/tmp/newer-start"]);
    trusted = true;
    retry!();
    const started = await newStart;
    expect(started).toBeDefined();
    expect(client.shownSession()?.sessionId).toBe(started);
    // The retry started the newer folder's session. Read its folder from the daemon's listing: the
    // mock's new session carries its seeded "This Mac" host (acpmux itself sends none), and
    // shownSession() names a folder only for a session with no host.
    const listed = (await daemon.answer("_acpmux/watch", {})) as { sessions: { sessionId: string; cwd?: string }[] };
    expect(listed.sessions.find((session) => session.sessionId === started)?.cwd).toBe("/tmp/newer-start");
  } finally {
    client.close();
  }
});

test("a retained New Tab start rejects Trust refusal when this remote origin cannot answer it", async () => {
  const fixture = await startFixture(false, true);
  const { client, requests } = fixture;
  try {
    const start = client.create("claude", undefined, undefined, true, undefined, true);
    // Held as a value: an un-awaited expect(start).rejects waits for the start to settle right
    // there, before the refusal below is sent, and the test hangs.
    const refused = start.then(
      () => undefined,
      (error: unknown) => error,
    );
    await fixture.requested;
    fixture.rejectStart(
      Object.assign(new Error("Trust must be answered on the host"), {
        data: { reason: "trust.pending", cwd: "/tmp/remote-trust" },
      }),
    );
    expect(((await refused) as Error | undefined)?.message).toBe("Trust must be answered on the host");
    expect(client.shownSession()).toBeUndefined();
    expect(requests.filter((request) => request.method === "session/prompt")).toEqual([]);
    // Once the host has answered, an explicit retry must be able to start again.
    expect(await client.create("claude", undefined, undefined, true, undefined, true)).toBeDefined();
  } finally {
    client.close();
  }
});

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
