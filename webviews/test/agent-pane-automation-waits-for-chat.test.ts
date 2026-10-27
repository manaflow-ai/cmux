// An automation verb (`debug.agent_pane` new_chat, send_prompt, ...) runs the chat's own action,
// which the page installs once its chat connects to acpmux. A verb sent right after the pane opens
// waits for it instead of reaching the native host.
//
// Before: the verb fell through to the native host, which has no chat verbs, and a capture's
// new_chat failed with only the op's name: `debug.agent_pane: cmux.agent.chat.new`. And new_chat and
// send_prompt wait for the chat before their accept window, so a chat that never connects is an error.
import { expect, test } from "bun:test";
import { newChat, pageAction, sendPrompt, type AutomationHost } from "../src/agent-session/acpmux/automation";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

type Action = (params: Record<string, unknown>) => Promise<unknown>;

test("a verb waits for the chat's action and runs it", async () => {
  let actions: Record<string, Action> | undefined;
  let pauses = 0;
  const pause = async () => {
    pauses += 1;
    // The chat connects on the third look.
    if (pauses === 2) actions = { "chat.new": async (params) => ({ started: params.harness }) };
  };
  const action = await pageAction(() => actions, "chat.new", 1_000, pause);
  expect(await action({ harness: "fake" })).toEqual({ started: "fake" });
  expect(pauses).toBe(2);
});

test("a chat that never connects names the verb and the wait, not a host op", async () => {
  let looks = 0;
  const error = await pageAction(
    () => {
      looks += 1;
      return undefined;
    },
    "chat.new",
    0,
    async () => undefined,
  ).catch((caught: unknown) => caught as Error);
  expect(error).toBeInstanceOf(Error);
  expect((error as Error).message).toBe("chat.new: the chat did not connect to acpmux within 0 s");
  expect((error as Error).message).not.toContain("cmux.agent.");
  expect(looks).toBe(1);
});

function host(actions: () => Record<string, Action> | undefined, waitMs: number): AutomationHost {
  const snapshot = {
    type: "snapshot",
    rows: [],
    sessions: [],
    connection: "connected",
    isWorking: false,
    sessionId: "s1",
  };
  return {
    snapshot: () => snapshot as unknown as AcpmuxSnapshot,
    call: async (method, params) => (await pageAction(actions, method, waitMs))(params ?? {}),
    ready: async (method) => void (await pageAction(actions, method, waitMs)),
    selectSession: () => {},
    openDiff: () => {},
    diff: () => ({ open: false, paths: [] }),
  };
}

test("new_chat and send_prompt on a chat that never connects are errors, not accepted after the window", async () => {
  // The readiness wait (50 ms) outlasts the accept window (10 ms): before, the window won and the verb
  // reported a pending chat or a sent prompt that never ran.
  const never = host(() => undefined, 50);
  expect(await newChat(never, "fake", undefined, 10)).toEqual({
    error: "chat.new: the chat did not connect to acpmux within 0 s",
  });
  expect(await sendPrompt(never, "hi", 10)).toEqual({
    error: "chat.send: the chat did not connect to acpmux within 0 s",
  });
});

test("new_chat on a chat that connects late runs the chat's action", async () => {
  let actions: Record<string, Action> | undefined;
  const started: unknown[] = [];
  setTimeout(() => {
    actions = {
      "chat.new": async (params) => void started.push(params),
    };
  }, 30);
  // The accept window (10 ms) is shorter than the connect (30 ms): the verb waits for the chat first.
  expect(
    await newChat(
      host(() => actions, 1_000),
      "fake",
      undefined,
      10,
    ),
  ).toEqual({ sessionId: "s1" });
  expect(started).toEqual([{ harness: "fake" }]);
});

test("send_prompt on a chat that connects late runs the chat's send", async () => {
  let actions: Record<string, Action> | undefined;
  const sent: unknown[] = [];
  setTimeout(() => {
    actions = {
      // A turn runs past the accept window: the prompt is reported sent, its turn not ended.
      "chat.send": (params) => {
        sent.push(params);
        return new Promise(() => {});
      },
    };
  }, 30);
  expect(
    await sendPrompt(
      host(() => actions, 1_000),
      "hi",
      10,
    ),
  ).toEqual({
    sent: true,
    turnEnded: false,
    sessionId: "s1",
  });
  expect(sent).toEqual([{ text: "hi" }]);
});
