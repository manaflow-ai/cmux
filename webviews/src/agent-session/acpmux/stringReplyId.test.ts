import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  if (saved.window === undefined) delete scope.window;
  else scope.window = saved.window;
  if (saved.document === undefined) delete scope.document;
  else scope.document = saved.document;
});

test("a JSON-RPC reply with a string id settles its pending request", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    const direct = client as any;
    const reply = direct.expectReply("native-return-1", "_acpmux/permission_respond", 1_000);
    direct.receive(
      JSON.stringify({
        jsonrpc: "2.0",
        id: "native-return-1",
        result: { accepted: true },
      }),
    );
    await expect(reply).resolves.toEqual({ accepted: true });
  } finally {
    client.close?.();
  }
});
