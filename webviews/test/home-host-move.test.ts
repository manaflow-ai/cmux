// Audit row 35 (unimpl-audit-actions.md): Cmd-Shift-[ / ] (`home.previousConversation` /
// `home.nextConversation`) did nothing while the docked Home showed Channels. The host now asks the
// page to move through its list with the page op `home.moveConversation {delta}`, which runs the
// same move as the page's own Option-Up/Down and answers whether a conversation opened.
import { expect, test } from "bun:test";
import { MOVE_CONVERSATION_OP, serveHostMove } from "../src/pages/home-channels/hostMove";
import type { PageClient, PageHandler } from "../src/pages/shared/pageClient";

function host(): { client: PageClient; handlers: Map<string, PageHandler> } {
  const handlers = new Map<string, PageHandler>();
  const client = {
    call: async () => undefined,
    subscribe: async () => () => {},
    handle: (op: string, handler: PageHandler) => {
      handlers.set(op, handler);
      return () => handlers.delete(op);
    },
  } as unknown as PageClient;
  return { client, handlers };
}

test("the host's move runs the page's list move and answers whether it moved", async () => {
  const { client, handlers } = host();
  const moves: number[] = [];
  const stop = serveHostMove(client, () => (delta) => {
    moves.push(delta);
    return delta === 1;
  });
  const handler = handlers.get(MOVE_CONVERSATION_OP);
  expect(handler).toBeDefined();
  expect(await handler!({ delta: 1 })).toEqual({ moved: true });
  expect(await handler!({ delta: -1 })).toEqual({ moved: false });
  expect(moves).toEqual([1, -1]);
  stop();
  expect(handlers.has(MOVE_CONVERSATION_OP)).toBe(false);
});

test("a delta other than 1 or -1 moves nothing", async () => {
  const { client, handlers } = host();
  const moves: number[] = [];
  serveHostMove(client, () => (delta) => {
    moves.push(delta);
    return true;
  });
  const handler = handlers.get(MOVE_CONVERSATION_OP)!;
  expect(await handler({ delta: 3 })).toEqual({ moved: false });
  expect(await handler({})).toEqual({ moved: false });
  expect(moves).toEqual([]);
});

test("the latest move runs (the page re-renders with a new list)", async () => {
  const { client, handlers } = host();
  let current: (delta: 1 | -1) => boolean = () => false;
  serveHostMove(client, () => current);
  current = () => true;
  expect(await handlers.get(MOVE_CONVERSATION_OP)!({ delta: -1 })).toEqual({ moved: true });
});
