// l10n-allow-file: test fixture relay refusals, not shipped UI.
// cmux#55066: the web update served NIGHTLY a3a24c8 a page newer than its relay. The page's
// `_acpmux/attach` carried `attending` (#52780), which that relay's params rule did not know, and it
// refused every chat's open: "cmux blocked opening this chat" over a blank chat, Retry failing the same
// way. The relay's own frame (AcpmuxPaneMethods.refusal) names the key in `data.detail`. The page sends
// the request again without the key, as a relay from #49717 on drops it, and the chat opens.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { unknownParamRefused, withoutParam } from "./relaySkew";

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
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const turns = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

/// NIGHTLY a3a24c8's params rule for the methods a chat's open sends (AcpmuxPaneMethods+Params.swift at a3a24c8).
const OLD_RULE: Record<string, readonly string[]> = {
  "_acpmux/attach": ["sessionId", "limit", "maxBytes", "kinds", "eventStream", "visible", "waitLogs", "settled", "hold", "afterSeq"],
  "_acpmux/view": ["sessionId", "visible"],
};

/// The relay's refusal frame for request `id` (AcpmuxPaneMethods.refusal), naming the first unknown key.
function refusal(id: number, method: string, key: string): string {
  return JSON.stringify({
    jsonrpc: "2.0",
    id,
    error: {
      code: -32601,
      message: "Refused by the cmux host",
      data: { code: "transport.intent_invalid", origin: "native", method, detail: `unknown param "${key}"` },
    },
  });
}

test("a chat opens through a relay older than its page, which refuses the page's new attach key", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve()) as unknown as {
    send: (raw: string) => void;
    onmessage: ((message: { data: string }) => void) | null;
    onopen: (() => void) | null;
  };
  await turns();
  const answer = socket.send.bind(socket);
  const refused: string[] = [];
  const attaches: Record<string, unknown>[] = [];
  socket.send = (raw) => {
    const request = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, unknown> };
    const known = OLD_RULE[request.method];
    if (request.id !== undefined && known) {
      if (request.method === "_acpmux/attach") attaches.push(request.params ?? {});
      const unknown = Object.keys(request.params ?? {}).find((key) => !known.includes(key));
      if (unknown) {
        refused.push(`${request.method} ${unknown}`);
        queueMicrotask(() => socket.onmessage?.({ data: refusal(request.id!, request.method, unknown) }));
        return;
      }
    }
    answer(raw);
  };
  let painted = false;
  const errors: string[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      const state = snapshot as { rows?: unknown[]; error?: unknown };
      if (Array.isArray(state.rows) && state.rows.length > 0) painted = true;
      if (typeof state.error === "string" && state.error) errors.push(state.error);
    },
    undefined,
    () => {
      queueMicrotask(() => socket.onopen?.());
      return socket as unknown as WebSocket;
    },
  );
  try {
    for (let i = 0; i < 200 && !painted; i += 1) await turns();
    // Before the fix: every attach was refused and the chat never opened.
    expect(refused).toContain("_acpmux/attach attending");
    expect(painted).toBe(true);
    // The attach that opened it carried every key the older relay knows, and not the one it refused.
    const last = attaches.at(-1)!;
    expect(last).not.toHaveProperty("attending");
    expect(last).toMatchObject({ sessionId: mockHost.sessionId, eventStream: true });
    expect(errors.filter((error) => /blocked opening/.test(error))).toEqual([]);
  } finally {
    client.close();
  }
});

test("only a relay's unknown-param refusal of a key the request carries is sent again", () => {
  const params = { sessionId: "s", attending: true, visible: true };
  const refused = (detail: unknown, code = "transport.intent_invalid") => ({ code, detail });
  expect(unknownParamRefused(refused('unknown param "attending"'), params)).toBe("attending");
  expect(withoutParam(params, "attending")).toEqual({ sessionId: "s", visible: true });
  // Another code, another rule's words, a key it does not carry, or the session itself: refused as before.
  expect(unknownParamRefused(refused('unknown param "attending"', "transport.denied"), params)).toBeUndefined();
  expect(unknownParamRefused(refused("mode field outside set_mode"), params)).toBeUndefined();
  expect(unknownParamRefused(refused('unknown param "seenSeq"'), params)).toBeUndefined();
  expect(unknownParamRefused(refused('unknown param "sessionId"'), params)).toBeUndefined();
  expect(unknownParamRefused(new Error('unknown param "attending"'), params)).toBeUndefined();
});
