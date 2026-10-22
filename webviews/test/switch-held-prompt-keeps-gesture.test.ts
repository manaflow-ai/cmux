// l10n-allow-file: test fixtures, not shipped UI.
// #23031: a new chat's first message often came back "Not sent. Press Retry". The harness switch
// holds a prompt sent while the chat's harness starts and sends it once the session opens, but it
// sent it with no gesture ticket: the relay then needed the Enter's gesture still live (30 s), and
// a cold harness takes longer. The switch now keeps the send's gesture as a ticket for that prompt
// when the person presses Enter, and the prompt goes with it.
import { expect, test } from "bun:test";
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
  const turn = pane.store.send("Add a remove command");
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
  const first = pane.store.send("first");
  const second = pane.store.send("second");
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
  const turn = pane.store.send("remote");
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
  const turn = pane.store.send("after reconnect");
  expect(pane.intents).toHaveLength(1);
  // The connection drops while the harness starts; the next client opens the started chat.
  pane.store.disconnect(before);
  pane.store.connect(pane.port(async () => "s2"));
  expect(await opened).toBe("s2");
  await turn;
  expect(pane.sent).toEqual([{ text: "after reconnect", promptId: expect.any(String) }]);
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
  await pane.store.send("retry");
  expect(pane.intents).toEqual([]);
  expect(pane.sent).toEqual([{ text: "retry", promptId: expect.any(String) }]);
});
