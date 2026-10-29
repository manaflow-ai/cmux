// The direct client's reconnect backoff rests while the page is hidden (MQ4b): a
// connection lost on a hidden page opens no socket for a minute, and the show opens one at once.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { PageLifecycle } from "../../pages/shared/pageLifecycle";
import { FakeLifecycleDocument, FakePollClock, flushMicrotasks } from "../../../test/support/pagePollFakes";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

test("a connection lost on a hidden page opens no socket for a minute; the show opens one", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const doc = new FakeLifecycleDocument();
  const clock = new FakePollClock(() => flushMicrotasks(20));
  const sockets: InstanceType<typeof MockAcpmuxSocket>[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => {
      const socket = new MockAcpmuxSocket(() => Promise.resolve());
      sockets.push(socket);
      return socket as unknown as WebSocket;
    },
    undefined,
    undefined,
    { lifecycle: new PageLifecycle(doc), timers: clock },
  );
  try {
    expect(sockets.length).toBe(1);
    doc.hide();
    // acpmux went away while the page was hidden.
    sockets[0]!.onclose?.();
    await flushMicrotasks(20);
    expect(clock.armed).toBe(0);
    await clock.advance(60_000);
    expect(sockets.length).toBe(1);

    doc.show();
    await flushMicrotasks(20);
    expect(sockets.length).toBe(2);
  } finally {
    client.close();
  }
});
