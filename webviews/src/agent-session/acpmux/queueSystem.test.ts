// acpmux's own queued prompts (a surge digest, a subagent's resume) are classed by their origin,
// never their words, and kept out of the person's steer rows. Leo, 2026-11-24: "these held during
// message surge, esume subagent things... maybe shouldn't look liek they're in the steer thing."
import { expect, test } from "bun:test";
import { mergeQueue, systemKindOf, withSystem } from "./direct/queue";
import { ownQueue, systemQueue } from "./conversation/queuedMessages";

const surge = "Held during a message surge: 10 message(s) in 8 thread(s) need you";

test("a queued record's provenance names acpmux's own prompts, and nothing else", () => {
  expect(systemKindOf({ _meta: { provenance: { kind: "surge_digest" } } })).toBe("surge_digest");
  expect(systemKindOf({ _meta: { provenance: { kind: "subagent_resume" } } })).toBe("subagent_resume");
  expect(systemKindOf({ _meta: { provenance: { kind: "agent_message" } } })).toBeUndefined();
  expect(systemKindOf({ _meta: {} })).toBeUndefined();
  expect(systemKindOf(undefined)).toBeUndefined();
});

test("an agent's message or a guest's prompt is never acpmux's own", () => {
  const message = { name: "lane", sessionId: "s", text: "hi", raw: "hi" };
  expect(withSystem({ id: "a", prompt: "hi", message }, "surge_digest").system).toBeUndefined();
  expect(withSystem({ id: "p", prompt: surge }, "surge_digest").system).toBe("surge_digest");
  expect(withSystem({ id: "p", prompt: surge }, undefined).system).toBeUndefined();
});

test("the listing's origin classes a row, whatever its text says", () => {
  const listed = [
    { promptId: "d", prompt: surge, origin: "acpmux" },
    { promptId: "p", prompt: surge, origin: "person" },
  ];
  const queue = mergeQueue([], listed);
  expect(queue.map((entry) => entry.system)).toEqual(["acpmux", undefined]);
  expect(ownQueue(queue).map((entry) => entry.id)).toEqual(["p"]);
  expect(systemQueue(queue).map((entry) => entry.id)).toEqual(["d"]);
});

test("an acpmux that lists no origin is read from its listed provenance, and keeps the record's class", () => {
  const listed = [{ promptId: "d", prompt: surge, provenance: { kind: "surge_digest" } }];
  expect(mergeQueue([], listed)[0]?.system).toBe("surge_digest");
  const had = [{ id: "r", prompt: "Resume it", system: "subagent_resume" }];
  expect(mergeQueue(had, [{ promptId: "r", prompt: "Resume it" }])[0]?.system).toBe("subagent_resume");
});

test("a row the person edited is theirs again", () => {
  const had = [{ id: "d", prompt: surge, system: "surge_digest" }];
  const queue = mergeQueue(had, [{ promptId: "d", prompt: "my words", origin: "person" }], undefined, new Set(["d"]));
  expect(queue[0]?.system).toBeUndefined();
  expect(ownQueue(queue).length).toBe(1);
});
