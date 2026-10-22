// l10n-allow-file: test fixture prompts, not shipped UI.
// The pane's hold for prompts sent while the folder's trust question is open (trustHeld.ts, Leo
// 2026-10-21 P0). Every one waits, none is dropped by Not now, and after Trust they go one at a
// time, in order, each once acpmux took the one before; a prompt removed or edited meanwhile goes
// as it is now. One acpmux refuses goes back into the composer (its ticket is spent), and after a
// trust refusal the rest wait for the next answer.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useTrustHeldPrompts } = await import("../src/agent-session/acpmux/trustHeld");
type Held = ReturnType<typeof useTrustHeldPrompts>;
type Entry = Parameters<Parameters<typeof useTrustHeldPrompts>[0]["send"]>[0];

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

/// A stand-in for acpmux: each prompt waits until the test takes or refuses it.
function standIn() {
  const sent: { entry: Entry; take(): void; refuse(error: unknown): void }[] = [];
  const putBack: string[] = [];
  return {
    sent,
    putBack,
    send: (entry: Entry) =>
      new Promise<unknown>((take, refuse) => sent.push({ entry, take: () => take(undefined), refuse })),
    reserve: async (promptId: string) => `ticket-${promptId}`,
    put: (entry: Entry) => void putBack.push(entry.text),
  };
}
const trustRefusal = Object.assign(new Error("trust"), { reason: "trust.pending" });

let shown: Held | undefined;
function Probe({
  acpmux,
  holds,
  chat = "chat-1",
  cwd = "/Users/you/src/app",
}: {
  acpmux: ReturnType<typeof standIn>;
  holds: boolean;
  chat?: string;
  cwd?: string;
}) {
  shown = useTrustHeldPrompts({
    chat,
    cwd,
    holds,
    send: acpmux.send,
    reserve: acpmux.reserve,
    putBack: acpmux.put,
    refusedForTrust: (error) => error === trustRefusal,
  });
  return null;
}
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

test("every prompt sent under the question waits, and they go in order after Trust", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="a" acpmux={acpmux} holds />));
  await act(async () => shown!.hold("first", []));
  await act(async () => shown!.hold("second", []));
  await act(async () => shown!.hold("third", []));
  expect(shown!.rows.map((row) => [row.prompt, row.held])).toEqual([
    ["first", true],
    ["second", true],
    ["third", true],
  ]);
  // Not now (the folder stays held): nothing goes and nothing is dropped.
  await settle();
  expect(acpmux.sent).toEqual([]);
  expect(shown!.rows).toHaveLength(3);
  const second = shown!.rows[1]!.id;
  await act(async () => shown!.remove(shown!.rows[2]!.id));
  await act(async () => shown!.edit(second, { op: "update", text: "second, edited" }));

  // Trust: one at a time, each once acpmux took the one before, with its own ticket.
  await act(async () => root.render(<Probe key="a" acpmux={acpmux} holds={false} />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["first"]);
  expect(await acpmux.sent[0]!.entry.ticket).toBe(`ticket-${acpmux.sent[0]!.entry.id}`);
  acpmux.sent[0]!.take();
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["first", "second, edited"]);
  acpmux.sent[1]!.take();
  await settle();
  expect(acpmux.sent).toHaveLength(2);
  expect(shown!.rows).toEqual([]);
});

test("a refused prompt goes back into the composer; after a trust refusal the rest wait", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds chat="chat-2" />));
  await act(async () => shown!.hold("one", []));
  await act(async () => shown!.hold("two", []));
  await act(async () => shown!.hold("three", []));
  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds={false} chat="chat-2" />));
  await settle();
  // acpmux's record changed meanwhile: it refuses, and the pane reads the folder again. The refused
  // prompt's ticket is spent, so it goes back into the composer; the others keep waiting.
  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds chat="chat-2" />));
  acpmux.sent[0]!.refuse(trustRefusal);
  await settle();
  expect(acpmux.putBack).toEqual(["one"]);
  expect(shown!.rows.map((row) => row.prompt)).toEqual(["two", "three"]);

  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds={false} chat="chat-2" />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["one", "two"]);
  // Another refusal (the sandbox): back into the composer, and the next one goes.
  acpmux.sent[1]!.refuse(new Error("sandbox"));
  await settle();
  expect(acpmux.putBack).toEqual(["one", "two"]);
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["one", "two", "three"]);
});

test("a new chat's prompts follow it into the session its first one started, in the folder the host filled in", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="d" acpmux={acpmux} holds chat={undefined} cwd="/Users/you/picked" />));
  await act(async () => shown!.hold("start it", []));
  await act(async () => shown!.hold("then this", []));
  await act(async () => root.render(<Probe key="d" acpmux={acpmux} holds={false} chat={undefined} cwd="/Users/you/picked" />));
  await settle();
  // Only the first goes: it starts the chat, and no second start goes before its session shows.
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["start it"]);
  acpmux.sent[0]!.take();
  await settle();
  expect(acpmux.sent).toHaveLength(1);
  // The session shows, in the folder acpmux resolved (not the one picked).
  await act(async () => root.render(<Probe key="d" acpmux={acpmux} holds={false} chat="chat-new" cwd="/private/you/picked" />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["start it", "then this"]);
  expect(acpmux.sent[1]!.entry.chat).toBe("chat-new");
});

test("a page about to let go takes every held prompt out", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="e" acpmux={acpmux} holds chat="chat-5" />));
  await act(async () => shown!.hold("kept one", []));
  await act(async () => shown!.hold("kept two", []));
  let released: { text: string }[] = [];
  await act(async () => void (released = shown!.release()));
  expect(released.map((entry) => entry.text)).toEqual(["kept one", "kept two"]);
  expect(shown!.rows).toEqual([]);
  await act(async () => root.render(<Probe key="e" acpmux={acpmux} holds={false} chat="chat-5" />));
  await settle();
  expect(acpmux.sent).toEqual([]);
});

test("another chat's held prompts neither show nor go there", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="c" acpmux={acpmux} holds chat="chat-3" />));
  await act(async () => shown!.hold("for chat 3", []));
  await act(async () => root.render(<Probe key="c" acpmux={acpmux} holds={false} chat="chat-4" />));
  await settle();
  expect(shown!.rows).toEqual([]);
  expect(acpmux.sent).toEqual([]);
});
