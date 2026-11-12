// Prompts sent while a new chat starts leave the composer at once as queued rows and go out in
// order once the chat takes the one before (startingSends.ts).
import { expect, test } from "bun:test";
import { inlineToken, type ComposerAttachment } from "./attachments";
import { inlinePrompt } from "./inlinePrompt";
import { StartingSends, startingQueueEntry } from "./startingSends";

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

// #41016: a queued row drew the draft as it was, each attachment as U+FFFC, its id, U+FFFC.
const image = {
  id: "0ffcff4e-5219-4332-9ceb-9d0acc03a47a",
  kind: "image",
  name: "image.png",
  preview: "data:image/png;base64,AA==",
  data: "AA==",
  mimeType: "image/png",
} as unknown as ComposerAttachment;
const pasted = {
  id: "37e67889-51d8-415a-beed-6d890ed57505",
  kind: "pasted",
  name: "Pasted text",
  text: "HELLO",
} as unknown as ComposerAttachment;

test("a waiting row shows its words and its pictures, never an attachment's id", () => {
  const row = {
    id: "starting-1",
    text: `look ${inlineToken(image.id)} at ${inlineToken(pasted.id)} this`,
    attachments: [image, pasted],
  };
  const entry = startingQueueEntry(row);
  expect(entry.prompt).toBe("look  at HELLO this");
  expect(entry.prompt).not.toContain("\uFFFC");
  expect(entry.images?.length).toBe(1);
});

test("an edited waiting row keeps its picture in place and sends a pasted chip's text once", async () => {
  const h = harness();
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  h.sends.add("first", [], h.go);
  h.sends.add(
    `hi ${inlineToken(image.id)} ${inlineToken(pasted.id)} end`,
    [image, pasted],
    async (text, attachments) => {
      sent.push({ text, attachments });
    },
  );
  const waiting = h.sends.rows[1]!;
  const shown = startingQueueEntry(waiting).prompt;
  expect(shown).toBe("hi  HELLO end");
  expect(h.sends.edit(waiting.id, `${shown}!`)).toBe(true);
  await h.settle();
  h.gates.get("first")!.take();
  await h.settle();
  expect(sent).toHaveLength(1);
  const { text, attachments } = sent[0]!;
  expect(text).toBe(`hi ${inlineToken(image.id)} HELLO end!`);
  expect(attachments.map((attachment) => attachment.id)).toEqual([image.id]);
  // The prompt as it goes: HELLO once, the picture in its place.
  const parts = inlinePrompt(text, attachments);
  expect(JSON.stringify(parts).split("HELLO").length - 1).toBe(1);
});

test("an edited waiting row keeps a text file left in the strip apart from its words", async () => {
  const notes = {
    id: "5191ce85-b54c-4acd-9a1e-1f2e3d4c5b6a",
    kind: "text",
    name: "notes.txt",
    text: "BODY",
  } as unknown as ComposerAttachment;
  const h = harness();
  const sent: string[] = [];
  h.sends.add("first", [], h.go);
  h.sends.add("look", [notes], async (text) => void sent.push(text));
  await h.settle();
  const waiting = h.sends.rows[1]!;
  const shown = startingQueueEntry(waiting).prompt;
  expect(shown.startsWith("look\n\n")).toBe(true);
  expect(h.sends.edit(waiting.id, `${shown}!`)).toBe(true);
  await h.settle();
  h.gates.get("first")!.take();
  await h.settle();
  expect(sent).toHaveLength(1);
  expect(sent[0]!.startsWith("look\n\n")).toBe(true);
  expect(sent[0]!.split("BODY").length - 1).toBe(1);
});
