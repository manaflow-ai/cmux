// l10n-allow-file: test fixtures, not shipped UI.
// #23031: a new chat's first message often came back "Not sent. Press Retry". The harness switch
// holds a prompt sent while the chat's harness starts and sends it once the session opens, but it
// sent it with no gesture ticket: the relay then needed the Enter's gesture still live (30 s), and
// a cold harness takes longer. The switch now keeps the send's gesture as a ticket for that prompt
// when the person presses Enter, and the prompt goes with it.
import { expect, test } from "bun:test";

/// The person's Enter comes in a later turn than the pick that started the chat.
const laterTurn = () => new Promise((resolve) => setTimeout(resolve, 0));
import { HarnessSwitch, type GestureIntent } from "../src/agent-session/acpmux/harnessSwitch";

type Sent = { text: string; promptId: string; ticket?: string };

function harness(options: { startsOnSend?: boolean } = {}) {
  const store = new HarnessSwitch();
  const intents: GestureIntent[] = [];
  store.setHandlers({
    gesture: async (intent: GestureIntent) => {
      intents.push(intent);
      return `ticket-${intents.length}`;
    },
  });
  let started!: (sessionId: string) => void;
  const sent: Sent[] = [];
  const port = (create: () => Promise<string | undefined>) =>
    ({
      turnRunning: () => false,
      shown: () => undefined,
      create,
      leave: () => undefined,
      open: async (sessionId: string) => sessionId,
      send: async (text: string, _attachments: unknown, promptId: string, ticket?: string) => {
        sent.push({ text, promptId, ...(ticket ? { ticket } : {}) });
      },
      setModel: async () => undefined,
      setMode: async () => undefined,
      setConfig: async () => undefined,
      discard: () => undefined,
      prewarm: () => undefined,
      prewarmSupported: () => false,
      ...(options.startsOnSend ? { startsOnSend: () => true } : {}),
    }) as never;
  const slowStart = () => new Promise<string | undefined>((resolve) => (started = resolve));
  return { store, intents, sent, port, slowStart, start: (sessionId: string) => started(sessionId) };
}

test("a prompt held behind a slow start goes with the ticket its Enter took", async () => {
  const pane = harness();
  pane.store.connect(pane.port(pane.slowStart));
  // The pick starts the harness; the person presses Enter while it starts.
  const opened = pane.store.switchTo("claude", "/Users/dev");
  await laterTurn();
  const turn = pane.store.send("Add a remove command", [], undefined, undefined, true);
  // The ticket is asked for in the send itself, while the Enter's gesture is live.
  expect(pane.intents).toHaveLength(1);
  const intent = pane.intents[0]!;
  expect(intent.method).toBe("session/prompt");
  pane.start("s1");
  expect(await opened).toBe("s1");
  await turn;
  expect(pane.sent).toEqual([
    {
      text: "Add a remove command",
      promptId: (intent.params as { promptId: string }).promptId,
      ticket: "ticket-1",
    },
  ]);
});

test("only the first held prompt takes a ticket; the others go on a live gesture", async () => {
  const pane = harness();
  pane.store.connect(pane.port(pane.slowStart));
  const opened = pane.store.switchTo("claude", "/Users/dev");
  await laterTurn();
  const first = pane.store.send("first", [], undefined, undefined, true);
  const second = pane.store.send("second", [], undefined, undefined, true);
  pane.start("s1");
  await opened;
  await Promise.all([first, second]);
  expect(pane.intents).toHaveLength(1);
  expect(pane.sent.map((prompt) => [prompt.text, prompt.ticket])).toEqual([
    ["first", "ticket-1"],
    ["second", undefined],
  ]);
});

test("a seeded prompt keeps its host ticket and takes no gesture", async () => {
  const pane = harness();
  pane.store.connect(pane.port(pane.slowStart));
  const opened = pane.store.switchTo("claude", "/Users/dev");
  const turn = pane.store.send("seeded", [], undefined, "seed-prompt");
  pane.start("s1");
  await opened;
  await turn;
  expect(pane.intents).toEqual([]);
  expect(pane.sent).toEqual([{ text: "seeded", promptId: "seed-prompt" }]);
});

test("a chat on another machine leaves the Enter's gesture to the start it needs", async () => {
  const pane = harness({ startsOnSend: true });
  pane.store.connect(pane.port(async () => "s1"));
  const opened = pane.store.switchTo("claude", "/Users/dev");
  const turn = pane.store.send("remote", [], undefined, undefined, true);
  await opened;
  await turn;
  expect(pane.intents).toEqual([]);
  expect(pane.sent).toEqual([{ text: "remote", promptId: expect.any(String) }]);
});

test("a ticket taken before a reconnect is not sent on the new connection", async () => {
  const pane = harness();
  const before = pane.port(pane.slowStart);
  pane.store.connect(before);
  const opened = pane.store.switchTo("claude", "/Users/dev");
  await laterTurn();
  const turn = pane.store.send("after reconnect", [], undefined, undefined, true);
  expect(pane.intents).toHaveLength(1);
  // The connection drops while the harness starts; the next client opens the started chat.
  pane.store.disconnect(before);
  pane.store.connect(pane.port(async () => "s2"));
  expect(await opened).toBeUndefined();
  await expect(turn).rejects.toMatchObject({ handedBack: true });
  expect(pane.sent).toEqual([]);
});

test("a send that restarts a failed switch leaves the gesture to the new start", async () => {
  const pane = harness();
  let attempts = 0;
  pane.store.connect(
    pane.port(async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("harness exited");
      return "s2";
    }),
  );
  await pane.store.switchTo("claude", "/Users/dev");
  expect(pane.store.view().intent?.phase).toBe("failed");
  // Enter after the failure starts the harness again: its session/new may need this gesture.
  await pane.store.send("retry", [], undefined, undefined, true);
  expect(pane.intents).toEqual([]);
  expect(pane.sent).toEqual([{ text: "retry", promptId: expect.any(String) }]);
});

test("a seed with no host ticket takes no gesture: no key or click sent it", async () => {
  const pane = harness();
  pane.store.connect(pane.port(pane.slowStart));
  const opened = pane.store.switchTo("claude", "/Users/dev");
  // Onboarding's seeded task from a script: no promptId and no person behind the send.
  const turn = pane.store.send("seeded by a script");
  pane.start("s1");
  await opened;
  await turn;
  expect(pane.intents).toEqual([]);
  expect(pane.sent).toEqual([{ text: "seeded by a script", promptId: expect.any(String) }]);
});

test("a ticketed prompt held for the folder's Trust answer goes after Trust with its ticket", async () => {
  const pane = harness();
  const holds: string[] = [];
  pane.store.setHandlers({
    gesture: async () => "ticket-1",
    holdPrompt: (promptId: string) => holds.push(promptId),
  });
  let attempts = 0;
  let refuse!: (error: unknown) => void;
  pane.store.connect(
    pane.port(() => {
      attempts += 1;
      // The first start waits, then acpmux refuses it for the folder's Trust answer.
      if (attempts === 1) return new Promise<string | undefined>((_, fail) => (refuse = fail));
      return Promise.resolve("s1");
    }),
  );
  const opened = pane.store.switchTo("claude", "/Users/dev");
  await laterTurn();
  const turn = pane.store.send("after trust", [], undefined, undefined, true);
  refuse(Object.assign(new Error("trust"), { reason: "trust.pending", cwd: "/Users/dev" }));
  // The start's trust refusal settles over a few microtasks.
  for (let step = 0; step < 10 && pane.store.view().intent?.phase !== "trust"; step += 1) await Promise.resolve();
  expect(pane.store.view().intent?.phase).toBe("trust");
  // The send already kept its gesture: the trust refusal reserves no second one.
  expect(holds).toEqual([]);
  pane.store.resumeAfterTrust();
  expect(await opened).toBe("s1");
  await turn;
  expect(pane.sent.map((prompt) => [prompt.text, prompt.ticket])).toEqual([["after trust", "ticket-1"]]);
});

test("a send in the same turn as the pick leaves the gesture to the start it just sent", async () => {
  const pane = harness();
  pane.store.connect(pane.port(pane.slowStart));
  // The New Tab page: the agent pick and the Send in one handler.
  const opened = pane.store.switchTo("claude", "/Users/dev");
  const turn = pane.store.send("new tab ask", [], undefined, undefined, true);
  expect(pane.intents).toEqual([]);
  pane.start("s1");
  await opened;
  await turn;
  expect(pane.sent).toEqual([{ text: "new tab ask", promptId: expect.any(String) }]);
});
