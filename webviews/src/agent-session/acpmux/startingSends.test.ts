// Prompts sent while a new chat starts leave the composer at once as queued rows and go out in
// order once the chat takes the one before (startingSends.ts).
import { expect, test } from "bun:test";
import { LIVE_THINKING, turnView } from "./conversation/turns";
import { emptySnapshot } from "./snapshotCache";
import { queuedStartingSends, startingIn, StartingSends, withStartingPrompt, type StartingSend } from "./startingSends";

/** A send acpmux takes or refuses when the test says. */
function gate() {
  let take!: () => void;
  let refuse!: (error: unknown) => void;
  const promise = new Promise<void>((resolve, reject) => {
    take = resolve;
    refuse = reject;
  });
  return { promise, take, refuse };
}

function harness() {
  const shown: string[][] = [];
  const given: string[] = [];
  const sent: string[] = [];
  const gates = new Map<string, ReturnType<typeof gate>>();
  const sends = new StartingSends(
    (rows) => shown.push(rows.map((row) => row.text)),
    (text) => given.push(text),
    () => ({ visit: 1 }),
  );
  const go = (text: string) => {
    sent.push(text);
    const next = gate();
    gates.set(text, next);
    return next.promise;
  };
  // Lets every chained step run.
  const settle = async () => {
    for (let i = 0; i < 10; i++) await Promise.resolve();
  };
  return { sends, shown, given, sent, gates, go, settle };
}

test("a prompt sent while the first is still on its way shows at once and goes only once the first is taken", async () => {
  const h = harness();
  h.sends.add("first", [], h.go);
  h.sends.add("second", [], h.go);
  h.sends.add("third", [], h.go);
  await h.settle();
  expect(h.shown.at(-1)).toEqual(["first", "second", "third"]);
  expect(h.sent).toEqual(["first"]);
  h.gates.get("first")!.take();
  await h.settle();
  expect(h.sent).toEqual(["first", "second"]);
  expect(h.shown.at(-1)).toEqual(["second", "third"]);
  h.gates.get("second")!.take();
  await h.settle();
  h.gates.get("third")!.take();
  await h.settle();
  expect(h.sent).toEqual(["first", "second", "third"]);
  expect(h.shown.at(-1)).toEqual([]);
  expect(h.sends.busy).toBe(false);
});

test("a refused prompt comes back with every prompt behind it, in the order they were sent", async () => {
  const h = harness();
  h.sends.add("first", [], h.go);
  h.sends.add("second", [], h.go);
  h.sends.add("third", [], h.go);
  await h.settle();
  const [, , third] = h.sends.rows;
  h.gates.get("first")!.refuse(new Error("trust.pending"));
  await h.settle();
  expect(h.sent).toEqual(["first"]);
  // Each comes back before what the composer holds, so the last goes back first.
  expect(h.given).toEqual(["third", "second", "first"]);
  expect(h.shown.at(-1)).toEqual([]);
  // An unsaved edit of a row given back is not a second copy of it.
  h.sends.lost(third.id, "third, edited");
  expect(h.given).toEqual(["third", "second", "first"]);
  // A prompt sent after that goes at once.
  h.sends.add("again", [], h.go);
  await h.settle();
  expect(h.sent).toEqual(["first", "again"]);
});

test("a waiting prompt can be removed or edited until it goes, never once it went", async () => {
  const h = harness();
  h.sends.add("first", [], h.go);
  h.sends.add("second", [], h.go);
  h.sends.add("third", [], h.go);
  await h.settle();
  const [first, second, third] = h.sends.rows;
  expect(h.sends.remove(first.id)).toBe(false);
  expect(h.sends.edit(first.id, "changed")).toBe(false);
  expect(h.sends.remove(second.id)).toBe(true);
  expect(h.sends.edit(third.id, "third, edited")).toBe(true);
  expect(h.shown.at(-1)).toEqual(["first", "third, edited"]);
  h.gates.get("first")!.take();
  await h.settle();
  expect(h.sent).toEqual(["first", "third, edited"]);
  expect(h.sends.owns(third.id)).toBe(true);
  expect(h.sends.owns("acpmux-prompt")).toBe(false);
});

test("an edit saved while its prompt goes comes back once it went, and never when it was refused", async () => {
  const h = harness();
  h.sends.add("first", [], h.go);
  h.sends.add("second", [], h.go);
  await h.settle();
  const [first, second] = h.sends.rows;
  h.sends.lost(first.id, "first, edited");
  expect(h.given).toEqual([]);
  h.gates.get("first")!.take();
  await h.settle();
  expect(h.given).toEqual(["first, edited"]);
  h.sends.lost(second.id, "second, edited");
  h.gates.get("second")!.refuse(new Error("refused"));
  await h.settle();
  expect(h.given).toEqual(["first, edited", "second"]);
  // An edit of a prompt in acpmux's own queue that started comes back at once.
  h.sends.lost("acpmux-prompt", "kept");
  expect(h.given).toEqual(["first, edited", "second", "kept"]);
});

// Leo, 2026-11-06 ("why is this still happening"): a send the composer held for a pasted image
// bound its Enter at once (composer/heldSendGesture.test.tsx), and the image's upload then spent the
// host's one grant. When such a send queues behind a chat that is still starting, it goes with the
// gesture its Enter bound; a prompt queued without one (a script's) goes without.
test("a queued send goes with the gesture its Enter bound, and one without goes without", async () => {
  const h = harness();
  const carried: (string | undefined)[] = [];
  const go = (text: string, _attachments: unknown, gesture?: { promptId: string }) => {
    carried.push(gesture?.promptId);
    return h.go(text);
  };
  const ticket = Promise.resolve<string | undefined>("ticket-enter");
  h.sends.add("first", [], go);
  h.sends.add("with the screenshot", [], go, { promptId: "held-1", ticket });
  await h.settle();
  h.gates.get("first")!.take();
  await h.settle();
  h.gates.get("with the screenshot")!.take();
  await h.settle();
  expect(h.sent).toEqual(["first", "with the screenshot"]);
  expect(carried).toEqual([undefined, "held-1"]);
});

// Leo, 2026-11-09: "there's the gap between when you send off a message versus otherwise, like it's
// like there's a one-two discontinuity". A new chat's first prompt is the chat's first row from the
// send, with its Thinking line under it, while the chat still starts: never a queued row first that
// jumps into the transcript once the agent is up. The chat's own row for it has the same id.
test("a new chat's first prompt draws as its first row with the Thinking line, and later ones stay queued", () => {
  const sends = [
    { id: "p1", text: "first", attachments: [], at: 1, sentIn: { visit: 1 } },
    { id: "p2", text: "second", attachments: [], at: 2, sentIn: { visit: 1 } },
  ] satisfies StartingSend[];
  const drawn = withStartingPrompt(emptySnapshot(), sends);
  expect(drawn.rows.map((row) => [row.id, row.kind, row.text, row.pending])).toEqual([
    ["local-p1", "user", "first", true],
  ]);
  // The transcript draws the start-look Thinking line under it at once (conversation/turns.ts `waiting`).
  const shaped = turnView(drawn.rows, new Set(), { now: 10 });
  expect(shaped.map((row) => row.id)).toEqual(["local-p1", LIVE_THINKING]);
  // The composer's queue draws only the prompts after it.
  expect(queuedStartingSends(sends, drawn.rows).map((send) => send.id)).toEqual(["p2"]);
  // Once the chat's client draws the prompt (the same id), its row is the client's and nothing is added.
  const started = {
    ...emptySnapshot(),
    rows: [{ id: "local-p1", version: 1, at: 3, kind: "user", text: "first", pending: true }],
  };
  expect(withStartingPrompt(started, sends)).toBe(started);
  expect(queuedStartingSends(sends, started.rows).map((send) => send.id)).toEqual(["p2"]);
  // A chat with prompts of its own draws none.
  const going = { ...emptySnapshot(), rows: [{ id: "u1", version: 1, at: 0, kind: "user", text: "older" }] };
  expect(withStartingPrompt(going, sends)).toBe(going);
  expect(withStartingPrompt(emptySnapshot(), [])).toEqual(emptySnapshot());
});

test("a starting prompt keeps the id its send goes with", () => {
  const shown: string[][] = [];
  const sends = new StartingSends(
    (rows) => shown.push(rows.map((row) => row.id)),
    () => undefined,
    () => ({ visit: 1 }),
  );
  sends.add("first", [], () => new Promise(() => undefined), undefined, "prompt-1");
  sends.add("second", [], () => new Promise(() => undefined));
  expect(shown.at(-1)![0]).toBe("prompt-1");
  expect(shown.at(-1)![1]).toStartWith("starting-");
});

// Review of #39781: a prompt sent in a new chat is that chat's. Another chat opened while it still
// starts (an empty one too) draws none of it, in its transcript or its queue; the chat the new chat
// took draws it, as does the new chat itself; a prompt sent in an existing chat stays that chat's.
test("a starting prompt draws only in the chat it was sent in", () => {
  const sends = [
    { id: "p1", text: "first", attachments: [], at: 1, sentIn: { visit: 4 } },
    { id: "p2", text: "second", attachments: [], at: 2, sentIn: { visit: 4 } },
  ] satisfies StartingSend[];
  const ids = (shown: readonly StartingSend[]) => shown.map((send) => send.id);
  // The new chat, still starting.
  expect(startingIn(sends, { visit: 4 }, undefined)).toBe(sends);
  // The chat it took (its select moved the visit).
  expect(ids(startingIn(sends, { chat: "s-new", visit: 5 }, { sessionId: "s-new", visit: 4 }))).toEqual(["p1", "p2"]);
  // An empty chat opened while it starts, and another new chat.
  expect(ids(startingIn(sends, { chat: "s-empty", visit: 5 }, undefined))).toEqual([]);
  expect(ids(startingIn(sends, { chat: "s-empty", visit: 7 }, { sessionId: "s-new", visit: 4 }))).toEqual([]);
  expect(ids(startingIn(sends, { visit: 6 }, undefined))).toEqual([]);
  const empty = startingIn(sends, { chat: "s-empty", visit: 5 }, undefined);
  expect(withStartingPrompt(emptySnapshot(), empty).rows).toEqual([]);
  // A chat's own prompts, sent while it was shown, in any later visit of it.
  const own = [{ id: "p3", text: "third", attachments: [], at: 3, sentIn: { chat: "s-new", visit: 5 } }];
  expect(ids(startingIn(own, { chat: "s-new", visit: 9 }, undefined))).toEqual(["p3"]);
  expect(ids(startingIn(own, { chat: "s-other", visit: 9 }, undefined))).toEqual([]);
});

// Review of #39781: the first prompt's row draws what the chat's own sent row draws once it went
// (direct.ts `sentPrompt`): a pasted block's text and range, and the attachments a Retry sends again.
test("a new chat's first prompt row carries its paste and its attachments", () => {
  const paste = {
    id: "paste-1",
    kind: "pasted" as const,
    name: "log.txt",
    mimeType: "text/plain",
    size: 9,
    text: "line\nline",
  };
  const sends = [
    { id: "p1", text: "see this", attachments: [paste], at: 1, sentIn: { visit: 1 } },
  ] satisfies StartingSend[];
  const row = withStartingPrompt(emptySnapshot(), sends).rows[0]!;
  expect(row.text).toContain("line\nline");
  expect(row.pasted?.length).toBe(1);
  expect(row.retryAttachments).toEqual([paste]);
});
