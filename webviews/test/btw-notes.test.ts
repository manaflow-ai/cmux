import { expect, test } from "bun:test";
import { BtwNotes } from "../src/agent-session/acpmux/aside/btwNotes";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (id: string, at = Date.now() - 1000): AcpmuxRow => ({ id, version: 1, kind: "assistant", at, text: id });
const deferred = () => {
  let resolve!: (answer: string) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<string>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
};
const settled = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

test("an answer stays beside its ask when the main turn continues, without changing source rows", async () => {
  const notes = new BtwNotes();
  const first = row("main-output");
  const source = [first];
  const answer = deferred();
  notes.ask("main", "Why?", first, () => answer.promise);
  expect(source).toEqual([first]);
  expect(notes.rows(source, "main").map((entry) => entry.kind)).toEqual(["assistant", "btw"]);
  answer.resolve("Because the clock advanced.");
  await settled();
  const later = row("later-output", Date.now() + 1000);
  const shown = notes.rows([first, later], "main");
  expect(shown.map((entry) => entry.id)).toEqual([first.id, notes.snapshot()[0].id, later.id]);
  expect(shown[1].text).toBe("Because the clock advanced.");
  expect(source).toEqual([first]);
});

test("switching sessions while an answer waits cannot put it in the newly opened chat", async () => {
  const notes = new BtwNotes();
  const answer = deferred();
  const calls: string[] = [];
  notes.ask("original", "Which model?", undefined, (question, session) => {
    calls.push(`${session}:${question}`);
    return answer.promise;
  });
  expect(notes.rows([], "new-chat")).toEqual([]);
  answer.resolve("The original model.");
  await settled();
  expect(calls).toEqual(["original:Which model?"]);
  expect(notes.rows([], "new-chat")).toEqual([]);
  expect(notes.rows([], "original")[0].text).toBe("The original model.");
});

test("dismissal is final even if a late answer or refusal arrives", async () => {
  for (const fail of [false, true]) {
    const notes = new BtwNotes();
    const answer = deferred();
    notes.ask("main", "Why?", undefined, () => answer.promise);
    notes.dismiss(notes.snapshot()[0].id);
    if (fail) answer.reject(new Error("disconnected"));
    else answer.resolve("Late answer");
    await settled();
    expect(notes.rows([], "main")).toEqual([]);
  }
});

test("a folded-away anchor keeps the aside before later work and preserves repeated questions", () => {
  const notes = new BtwNotes();
  const anchor = row("working-line");
  const ask = () => new Promise<string>(() => {});
  notes.ask("main", "Why?", anchor, ask);
  notes.ask("main", "Why?", anchor, ask);
  const later = row("later", Date.now() + 1000);
  const shown = notes.rows([row("earlier"), later], "main");
  expect(shown.map((entry) => entry.kind)).toEqual(["assistant", "btw", "btw", "assistant"]);
  expect(new Set(shown.map((entry) => entry.id)).size).toBe(4);
});
