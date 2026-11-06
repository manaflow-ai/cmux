import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { receiveTransportEvent } from "../src/agent-session/acpmux/bridgeSocket";

let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
let savedWindow: unknown;

afterEach(() => {
  dom?.window.close();
  dom = undefined;
  if (savedWindow === undefined) delete scope.window;
  else scope.window = savedWindow;
  savedWindow = undefined;
});

function installWindow() {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
  savedWindow = scope.window;
  scope.window = dom.window;
}

const announcement = (id: string, sessionId = "session-one", permissionId = "permission-one") =>
  JSON.stringify({
    jsonrpc: "2.0",
    method: "_cmux/question_key_request",
    params: { id, sessionId, permissionId },
  });

test("a closed connection's paired question-key error reaches the card as a refusal", async () => {
  installWindow();
  const id = "question-key-closed";
  const result = new Promise<unknown>((resolve) => {
    window.addEventListener("cmux.question.key-request", (event) => {
      const detail = (event as CustomEvent<{ result: Promise<unknown> }>).detail;
      detail.result.then(resolve, resolve);
    });
  });
  receiveTransportEvent({
    connection: 901,
    frames: [
      announcement(id),
      JSON.stringify({
        jsonrpc: "2.0",
        id,
        error: {
          code: -32602,
          message: "invalid answer",
          data: { code: "transport.intent_invalid", reason: "invalid_answer" },
        },
      }),
    ],
  });
  const refusal = await result;
  expect(refusal).toBeInstanceOf(Error);
  expect((refusal as { code?: unknown }).code).toBe("transport.intent_invalid");
  expect((refusal as { reason?: unknown }).reason).toBe("invalid_answer");
});

test("stale unrelated, mismatched, and successful frames are ignored", () => {
  installWindow();
  let events = 0;
  window.addEventListener("cmux.question.key-request", () => events++);
  receiveTransportEvent({
    connection: 902,
    frames: [
      JSON.stringify({ method: "_acpmux/presence", params: {} }),
      announcement("question-key-mismatch"),
      JSON.stringify({ jsonrpc: "2.0", id: "question-key-other", error: { code: -32602, message: "no" } }),
      announcement("question-key-result"),
      JSON.stringify({ jsonrpc: "2.0", id: "question-key-result", result: {} }),
      JSON.stringify({ jsonrpc: "2.0", id: "ordinary", error: { code: -32602, message: "no" } }),
    ],
  });
  expect(events).toBe(0);
});
