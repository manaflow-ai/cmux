// l10n-allow-file: test fixture prompts, not shipped UI.
// The pane's hold for prompts sent while the folder's trust question is open (trustHeld.ts, Leo
// 2026-10-21 P0). Every one waits, none is dropped by Not now, and after Trust they go one at a
// time, in order, each once acpmux took the one before; a prompt removed or edited meanwhile goes
// as it is now, and a trust refusal holds it again.
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
function Probe({ acpmux, holds, chat = "chat-1" }: { acpmux: ReturnType<typeof standIn>; holds: boolean; chat?: string }) {
  shown = useTrustHeldPrompts({
    chat,
    cwd: "/Users/you/src/app",
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

test("a trust refusal holds the prompt again; another refusal puts it back in the composer", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds chat="chat-2" />));
  await act(async () => shown!.hold("one", []));
  await act(async () => shown!.hold("two", []));
  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds={false} chat="chat-2" />));
  await settle();
  // acpmux's record changed meanwhile: it refuses, and the pane reads the folder again.
  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds chat="chat-2" />));
  acpmux.sent[0]!.refuse(trustRefusal);
  await settle();
  expect(shown!.rows.map((row) => row.prompt)).toEqual(["one", "two"]);

  await act(async () => root.render(<Probe key="b" acpmux={acpmux} holds={false} chat="chat-2" />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["one", "one"]);
  acpmux.sent[1]!.refuse(new Error("sandbox"));
  await settle();
  expect(acpmux.putBack).toEqual(["one"]);
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["one", "one", "two"]);
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
