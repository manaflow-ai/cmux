// A prompt the host refuses for want of a real gesture (transport.gesture_required: no fresh key
// or click in the pane, e.g. dictation's autoSend after the session ended by itself) stays in the
// composer, and the pane says how to send it: again. Never the generic refusal's "Click the choice
// again", which is about a pick (cx-w2p8r).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

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
  // Put back exactly what was there: a global that was absent stays absent for later files.
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

test("a prompt refused for want of a gesture says to send it again", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { translate } = await import("./i18n");
  // The host relay's answer to a session/prompt with no gesture behind it.
  class RefusingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const answer = (this as unknown as { answer: (method: string, params: unknown) => Promise<unknown> }).answer.bind(
        this,
      );
      (this as unknown as { answer: typeof answer }).answer = (method, params) =>
        method === "session/prompt"
          ? Promise.reject(
              Object.assign(new Error(translate("transport.gestureRequired")), { code: "transport.gesture_required" }),
            )
          : answer(method, params);
    }
  }
  let rows: { kind: string; text?: string }[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as typeof rows),
    undefined,
    () => new RefusingHost() as unknown as WebSocket,
  );
  try {
    let accepted = false;
    // The composer's send: it holds the prompt until acpmux takes it (`accepted`).
    await client.send("ship it", [], undefined, () => (accepted = true)).catch(() => undefined);
    const notes = rows.filter((row) => row.kind === "notice").map((row) => row.text);
    expect(accepted).toBe(false);
    expect(rows.some((row) => row.kind === "user" && row.text === "ship it")).toBe(false);
    expect(notes).toEqual(["Not sent. Send it again."]);
  } finally {
    client.close?.();
  }
});
