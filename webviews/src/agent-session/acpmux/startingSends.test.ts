// Prompts sent while a new chat starts leave the composer at once as queued rows and go out in
// order once the chat takes the one before (startingSends.ts).
import { expect, test } from "bun:test";
import { StartingSends } from "./startingSends";

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
