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
const { movedOn, useTrustHeldPrompts, whereHeldGoes } = await import("../src/agent-session/acpmux/trustHeld");
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
  /// `take(session)`: acpmux took it, in `session` (a new chat's, once its start made it).
  const sent: { entry: Entry; take(session?: string): void; refuse(error: unknown): void }[] = [];
  const putBack: string[] = [];
  /// Each give-back, as one list: the pane restores a list in its order (App.tsx `giveBackTrustHeld`).
  const givenBack: string[][] = [];
  return {
    sent,
    putBack,
    givenBack,
    send: (entry: Entry) =>
      new Promise<string | undefined>((take, refuse) => sent.push({ entry, take: (session) => take(session), refuse })),
    reserve: async (promptId: string) => `ticket-${promptId}`,
    /// Given back behind (`behind`): after one a harness switch gave back itself.
    behind: [] as boolean[],
    put(entries: Entry[], behind?: boolean) {
      this.behind.push(behind === true);
      givenBack.push(entries.map((entry) => entry.text));
      putBack.push(...entries.map((entry) => entry.text));
    },
  };
}
const trustRefusal = Object.assign(new Error("trust"), { reason: "trust.pending" });

let shown: Held | undefined;
function Probe({
  acpmux,
  holds,
  chat,
  cwd = "/Users/you/src/app",
}: {
  acpmux: ReturnType<typeof standIn>;
  holds: boolean;
  /// Required: undefined is a new chat (no session yet), never a default chat.
  chat: string | undefined;
  cwd?: string;
}) {
  shown = useTrustHeldPrompts({
    chat,
    cwd,
    holds,
    send: acpmux.send,
    reserve: acpmux.reserve,
    putBack: (entries, behind) => acpmux.put(entries, behind),
    refusedForTrust: (error) => error === trustRefusal,
  });
  return null;
}
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

test("every prompt sent under the question waits, and they go in order after Trust", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="a" acpmux={acpmux} holds chat="chat-1" />));
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
  await act(async () => root.render(<Probe key="a" acpmux={acpmux} holds={false} chat="chat-1" />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["first"]);
  expect(await acpmux.sent[0]!.entry.ticket).toBe(`ticket-${acpmux.sent[0]!.entry.id}`);
  // A prompt sent now waits behind the ones still going (the pane holds it too).
  expect(shown!.pending()).toBe(true);
  acpmux.sent[0]!.take();
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["first", "second, edited"]);
  acpmux.sent[1]!.take();
  await settle();
  expect(acpmux.sent).toHaveLength(2);
  expect(shown!.rows).toEqual([]);
  expect(shown!.pending()).toBe(false);
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
  // Another refusal (the sandbox): back into the composer with the one after it, in their order;
  // none goes ahead of one refused.
  acpmux.sent[1]!.refuse(new Error("sandbox"));
  await settle();
  expect(acpmux.givenBack).toEqual([["one"], ["two", "three"]]);
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["one", "two"]);
  expect(shown!.rows).toEqual([]);
});

test("a new chat's prompts follow it into the session its start made, whatever chat shows meanwhile", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="d" acpmux={acpmux} holds chat={undefined} cwd="/Users/you/picked" />));
  await act(async () => shown!.hold("start it", []));
  await act(async () => shown!.hold("then this", []));
  await act(async () =>
    root.render(<Probe key="d" acpmux={acpmux} holds={false} chat={undefined} cwd="/Users/you/picked" />),
  );
  await settle();
  // Only the first goes: it starts the chat, and no second start goes before its session shows.
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["start it"]);
  // The start is slow, and the person opens another chat meanwhile: the backlog is not its.
  await act(async () => root.render(<Probe key="d" acpmux={acpmux} holds={false} chat="chat-other" />));
  acpmux.sent[0]!.take("chat-new");
  await settle();
  expect(acpmux.sent).toHaveLength(1);
  expect(shown!.rows).toEqual([]);
  // The new chat's session shows, in the folder acpmux resolved (not the one picked): its backlog goes.
  await act(async () =>
    root.render(<Probe key="d" acpmux={acpmux} holds={false} chat="chat-new" cwd="/private/you/picked" />),
  );
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["start it", "then this"]);
  expect(acpmux.sent[1]!.entry.chat).toBe("chat-new");
});

test("a start that names no session puts the new chat's other prompts back, never starts a second chat", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="h" acpmux={acpmux} holds chat={undefined} />));
  await act(async () => shown!.hold("start it", []));
  await act(async () => shown!.hold("and this", []));
  await act(async () => shown!.hold("and that", []));
  await act(async () => root.render(<Probe key="h" acpmux={acpmux} holds={false} chat={undefined} />));
  await settle();
  acpmux.sent[0]!.take(undefined);
  await settle();
  expect(acpmux.sent).toHaveLength(1);
  // Given back together, in the order they were sent.
  expect(acpmux.givenBack).toEqual([["and this", "and that"]]);
  expect(shown!.holdsAny()).toBe(false);
});

test("a refusal that comes after the person moved on holds the prompt in the chat it was sent in", async () => {
  const acpmux = standIn();
  // Sent in chat A; acpmux's trust refusal came once chat B (trusted) showed.
  await act(async () => root.render(<Probe key="i" acpmux={acpmux} holds={false} chat="chat-b" />));
  await act(async () => shown!.hold("for chat a", [], { chat: "chat-a", cwd: "/Users/you/a" }));
  await settle();
  expect(acpmux.sent).toEqual([]);
  expect(shown!.rows).toEqual([]);
  // It shows and goes in chat A, once A's folder is trusted.
  await act(async () => root.render(<Probe key="i" acpmux={acpmux} holds chat="chat-a" cwd="/Users/you/a" />));
  expect(shown!.rows.map((row) => row.prompt)).toEqual(["for chat a"]);
  await act(async () => root.render(<Probe key="i" acpmux={acpmux} holds={false} chat="chat-a" cwd="/Users/you/a" />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["for chat a"]);
});

test("a prompt going when the page quits comes back once, even if acpmux refuses it after", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="j" acpmux={acpmux} holds chat="chat-7" />));
  await act(async () => shown!.hold("going", []));
  await act(async () => shown!.hold("waiting", []));
  await act(async () => root.render(<Probe key="j" acpmux={acpmux} holds={false} chat="chat-7" />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["going"]);
  let released: { text: string }[] = [];
  await act(async () => void (released = shown!.release()));
  expect(released.map((entry) => entry.text)).toEqual(["going", "waiting"]);
  acpmux.sent[0]!.refuse(new Error("refused"));
  await settle();
  // It is in the draft already: nothing goes back into the composer a second time, and nothing else goes.
  expect(acpmux.putBack).toEqual([]);
  expect(acpmux.sent).toHaveLength(1);
});

test("a page that quits takes every held prompt out", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="e" acpmux={acpmux} holds chat="chat-5" />));
  await act(async () => shown!.hold("kept one", []));
  await act(async () => shown!.hold("kept two", []));
  // It is not let go while it holds them (AgentPageHibernation `holdsPrompts`).
  expect(shown!.holdsAny()).toBe(true);
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

test("a new chat's held prompts neither show nor go in a new chat in another folder", async () => {
  const acpmux = standIn();
  await act(async () =>
    root.render(<Probe key="f" acpmux={acpmux} holds chat={undefined} cwd="/Users/you/untrusted" />),
  );
  await act(async () => shown!.hold("for the untrusted folder", []));
  // The person picks a trusted folder for the new chat instead.
  await act(async () =>
    root.render(<Probe key="f" acpmux={acpmux} holds={false} chat={undefined} cwd="/Users/you/trusted" />),
  );
  await settle();
  expect(shown!.rows).toEqual([]);
  expect(acpmux.sent).toEqual([]);
  expect(shown!.pending()).toBe(false);
  // Back to the first folder, now trusted: its prompt goes there.
  await act(async () =>
    root.render(<Probe key="f" acpmux={acpmux} holds={false} chat={undefined} cwd="/Users/you/untrusted" />),
  );
  await settle();
  expect(acpmux.sent.map((sent) => [sent.entry.text, sent.entry.cwd])).toEqual([
    ["for the untrusted folder", "/Users/you/untrusted"],
  ]);
});

test("a prompt a harness switch handed back to the composer is not put back twice", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="g" acpmux={acpmux} holds chat="chat-7" />));
  await act(async () => shown!.hold("switching", []));
  await act(async () => root.render(<Probe key="g" acpmux={acpmux} holds={false} chat="chat-7" />));
  await settle();
  acpmux.sent[0]!.refuse(Object.assign(new Error("switch failed"), { handedBack: true }));
  await settle();
  expect(acpmux.putBack).toEqual([]);
  expect(shown!.rows).toEqual([]);
});

test("a prompt whose chat stopped showing before it went waits again, first, in its own chat", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="k" acpmux={acpmux} holds chat="chat-a" />));
  await act(async () => shown!.hold("first for a", []));
  await act(async () => shown!.hold("then for a", []));
  await act(async () => root.render(<Probe key="k" acpmux={acpmux} holds={false} chat="chat-a" />));
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["first for a"]);
  // Chat B showed while its ticket came: the send says so (App.tsx `sendTrustHeldNow`) and nothing went.
  await act(async () => root.render(<Probe key="k" acpmux={acpmux} holds={false} chat="chat-b" />));
  acpmux.sent[0]!.refuse(movedOn());
  await settle();
  expect(acpmux.putBack).toEqual([]);
  expect(shown!.rows).toEqual([]);
  expect(acpmux.sent).toHaveLength(1);
  // Back in chat A, they go in their order, the first under its own id (its ticket was not spent).
  await act(async () => root.render(<Probe key="k" acpmux={acpmux} holds={false} chat="chat-a" />));
  await settle();
  expect(acpmux.sent[1]!.entry.id).toBe(acpmux.sent[0]!.entry.id);
  acpmux.sent[1]!.take("chat-a");
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["first for a", "first for a", "then for a"]);
});

test("prompts the hold gives back go where they were typed, never into another chat's composer", () => {
  const entry = (text: string, chat: string | undefined, cwd = "/Users/you/a") =>
    ({ id: text, chat, cwd, text, attachments: [], ticket: Promise.resolve(undefined) }) as Entry;
  const held = [entry("a1", "chat-a"), entry("b1", "chat-b"), entry("new1", undefined), entry("a2", "chat-a")];
  const texts = (list: Entry[]) => list.map((item) => item.text);
  // Chat B shows: A's go into A's draft, B's and the new chat's into the composer.
  const showingB = whereHeldGoes(held, "chat-b", true);
  expect(texts(showingB.composer)).toEqual(["b1", "new1"]);
  expect(texts(showingB.drafts.get("chat-a")!)).toEqual(["a1", "a2"]);
  expect(showingB.later).toEqual([]);
  // No composer shows (a hand-off review in its place): every chat's go into its draft; the new
  // chat's wait for the next composer.
  const noComposer = whereHeldGoes(held, "chat-b", false);
  expect(noComposer.composer).toEqual([]);
  expect(texts(noComposer.drafts.get("chat-b")!)).toEqual(["b1"]);
  expect(texts(noComposer.drafts.get("chat-a")!)).toEqual(["a1", "a2"]);
  expect(texts(noComposer.later)).toEqual(["new1"]);
});

test("a new chat whose first held prompt is refused gives its whole backlog back, in order", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="l" acpmux={acpmux} holds chat={undefined} />));
  await act(async () => shown!.hold("start it", []));
  await act(async () => shown!.hold("and this", []));
  await act(async () => root.render(<Probe key="l" acpmux={acpmux} holds={false} chat={undefined} />));
  await settle();
  // Its start made a session, then acpmux refused the prompt (a spent ticket): the backlog would no
  // longer show anywhere, so it all comes back.
  acpmux.sent[0]!.refuse(new Error("gesture expired"));
  await settle();
  expect(acpmux.givenBack).toEqual([["start it", "and this"]]);
  expect(shown!.holdsAny()).toBe(false);
});

test("a new chat whose start made its session but showed another chat binds its backlog to that session", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="m" acpmux={acpmux} holds chat={undefined} />));
  await act(async () => shown!.hold("start it", []));
  await act(async () => shown!.hold("and this", []));
  await act(async () => root.render(<Probe key="m" acpmux={acpmux} holds={false} chat={undefined} />));
  await settle();
  // Its start made chat-a; chat-b showed before the prompt went (App.tsx: `movedOn(made)`).
  await act(async () => root.render(<Probe key="m" acpmux={acpmux} holds={false} chat="chat-b" />));
  acpmux.sent[0]!.refuse(movedOn("chat-a"));
  await settle();
  expect(acpmux.putBack).toEqual([]);
  expect(acpmux.sent).toHaveLength(1);
  // Back in chat-a, both show and go there, in order.
  await act(async () => root.render(<Probe key="m" acpmux={acpmux} holds chat="chat-a" />));
  expect(shown!.rows.map((row) => row.prompt)).toEqual(["start it", "and this"]);
  await act(async () => root.render(<Probe key="m" acpmux={acpmux} holds={false} chat="chat-a" />));
  await settle();
  acpmux.sent[1]!.take("chat-a");
  await settle();
  expect(acpmux.sent.map((sent) => sent.entry.text)).toEqual(["start it", "start it", "and this"]);
  expect(acpmux.sent.slice(1).map((sent) => sent.entry.chat)).toEqual(["chat-a", "chat-a"]);
});

test("a held prompt a failed harness switch gave back keeps the rest after it", async () => {
  const acpmux = standIn();
  await act(async () => root.render(<Probe key="n" acpmux={acpmux} holds chat="chat-s" />));
  for (const text of ["one", "two", "three"]) await act(async () => shown!.hold(text, []));
  await act(async () => root.render(<Probe key="n" acpmux={acpmux} holds={false} chat="chat-s" />));
  await settle();
  // The switch failed and put "one" back itself (`handedBack`): the rest go behind it, in order.
  acpmux.sent[0]!.refuse(Object.assign(new Error("switch failed"), { handedBack: true }));
  await settle();
  expect(acpmux.givenBack).toEqual([["two", "three"]]);
  expect(acpmux.behind).toEqual([true]);
  expect(acpmux.sent).toHaveLength(1);
});
