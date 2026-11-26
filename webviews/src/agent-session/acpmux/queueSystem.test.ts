// acpmux's own queued prompts (a surge digest, a subagent's resume) are classed by their origin,
// never their words, and kept out of the person's steer rows. Leo, 2026-11-24: "these held during
// message surge, esume subagent things... maybe shouldn't look liek they're in the steer thing."
import { expect, test } from "bun:test";
import { mergeQueue, systemKindOf, withSystem } from "./direct/queue";
import { ownQueue, systemQueue } from "./conversation/queuedMessages";
import { agentSideRows } from "./session-info/agentSide";

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

const tr = (key: string, values?: Record<string, unknown>) => (values ? `${key} ${JSON.stringify(values)}` : key);

test("Session Info lists the held surge, then acpmux's prompts, and never the person's or a resume's agent id", () => {
  // Leo, 2026-11-24, of the held bar over the composer: "it's also not useful to show this to the user".
  const raw = 'Your subagent "Cap" (agent id af0cbece62b15d0e1) failed (529). Resume it';
  const queue = [
    { id: "d", prompt: surge, system: "surge_digest" },
    { id: "r", prompt: raw, retry: { name: "Cap", agentId: "af0cbece62b15d0e1", error: "529" } },
    { id: "p", prompt: "mine" },
  ];
  const rows = agentSideRows(tr as never, { held: 35, needYou: 3, seq: 1 }, queue);
  expect(rows.map((row) => row.id)).toEqual(["held", "queued:d", "queued:r"]);
  expect(rows[0]?.trailing).toBe('surge.held {"n":35}');
  expect(rows[0]?.detail).toBe('surge.needYou {"n":3}');
  expect(rows[2]?.title).toBe("composer.queuedSubagentRetry Cap");
  expect(rows[2]?.help).not.toContain("agent id");
  expect(agentSideRows(tr as never, { held: 0, needYou: 0, seq: 1 }, [{ id: "p", prompt: "mine" }])).toEqual([]);
});
