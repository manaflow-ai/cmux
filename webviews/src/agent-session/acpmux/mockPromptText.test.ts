// The mock daemon records a prompt's words as acpmux does: attachments the composer placed in the
// text split its words into text blocks around them (attachments.ts promptBlocks), and the
// recorded text keeps every one of them, in order, never a pasted block's text (review of #26545:
// it kept only the first block, so words after an attachment were lost).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { had: "window" in scope, value: scope.window };

beforeAll(() => {
  scope.window = dom.window;
});
afterAll(() => {
  if (saved.had) scope.window = saved.value;
  else delete scope.window;
});

test("a prompt's words around a placed attachment are all recorded, a pasted block's are not", async () => {
  const { MockAcpmuxSocket } = await import("./mock");
  // Turns run at once: no step waits.
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const messages: any[] = [];
  socket.onmessage = ({ data }) => messages.push(JSON.parse(data));
  await new Promise<void>((resolve) => {
    socket.onopen = resolve;
  });
  const answer = (id: number) =>
    new Promise<any>((resolve) => {
      const check = () => {
        const found = messages.find((message) => message.id === id);
        if (found) resolve(found);
        else setTimeout(check, 0);
      };
      check();
    });
  socket.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "session/new", params: {} }));
  const { sessionId } = (await answer(1)).result;
  const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
  socket.send(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "session/prompt",
      params: {
        sessionId,
        prompt: [
          { type: "text", text: "look at " },
          { type: "image", mimeType: "image/png", data: png, name: "shot.png" },
          { type: "text", text: " and fix it" },
          { type: "text", text: "a pasted log", _meta: { cmux: { pasted: true } } },
        ],
      },
    }),
  );
  await answer(2);
  const echo = messages.find(
    (message) => message.params?.kind === "user_message" && message.params?.sessionId === sessionId,
  );
  expect(echo?.params.msg.text).toBe("look at  and fix it");
  expect(echo?.params.msg.images).toHaveLength(1);
});
