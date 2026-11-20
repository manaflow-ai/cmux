// l10n-allow-file: test fixtures.
// Continue in my own chat (agent-session/guest/continueOwn.ts): the text a guest carries to a chat on their own
// sign-in names each turn's author, keeps tool lines to their titles, never carries a prompt that did not
// send, and stays within the Continue In bound by leaving out the oldest turns.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { CONTINUE_LIMIT_BYTES, continueCapsule, copyContinue } from "../src/agent-session/guest/continueOwn";

const row = (fields: Partial<AcpmuxRow>) => ({ id: Math.random().toString(36), ...fields }) as AcpmuxRow;
const SOURCE = {
  title: "Fix the race",
  owner: "Leo",
  page: "https://share.cmux.dev/g/c2hhcmUtMTIzNDU2Nzg",
  agent: "Agent",
  intro:
    "I'm continuing a chat Leo shared with me (https://share.cmux.dev/g/c2hhcmUtMTIzNDU2Nzg). Here is what I could see of it:",
  cut: "(Earlier turns left out.)",
};

test("each turn under its author: the owner's own prompt, a guest's under their name, the agent's", () => {
  const text = continueCapsule(
    [
      row({ kind: "user", text: "why does the test flake?" }),
      row({
        kind: "assistant",
        text: "A race in the queue.",
        items: [{ tool: { title: "Read   queue.rs" } }] as AcpmuxRow["items"],
      }),
      row({ kind: "user", text: "can we lock it?", author: { id: "guest:s.g2", name: "Priya Raman" } }),
      row({ kind: "user", text: "still sending", pending: true }),
      row({ kind: "user", text: "failed one", failed: true }),
    ],
    SOURCE,
  )!;
  expect(text).toBe(
    [
      SOURCE.intro,
      "# Fix the race",
      "**Leo:**\nwhy does the test flake?",
      "**Agent:**\nA race in the queue.",
      "- Tool: Read queue.rs",
      "**Priya Raman:**\ncan we lock it?",
    ].join("\n\n"),
  );
  // The secret never rides along: the page is passed without its fragment and nothing adds one.
  expect(text).not.toMatch(/c2hhcmUtMTIzNDU2Nzg#/);
});

test("nothing sent yet: no continuation", () => {
  expect(continueCapsule([row({ kind: "user", text: "draft", queued: true })], SOURCE)).toBeUndefined();
});

test("over the bound: the newest turns that fit, after a note that earlier ones were left out", () => {
  const rows = Array.from({ length: 400 }, (_, index) =>
    row({ kind: index % 2 ? "assistant" : "user", text: `turn ${index} ${"é".repeat(200)}` }),
  );
  const text = continueCapsule(rows, SOURCE)!;
  expect(new TextEncoder().encode(text).length).toBeLessThanOrEqual(CONTINUE_LIMIT_BYTES);
  expect(text).toContain(SOURCE.cut);
  expect(text).toContain("turn 399 ");
  expect(text).not.toContain("turn 0 ");
  expect(text.indexOf(SOURCE.cut)).toBeLessThan(text.indexOf("turn 399 "));
});

test("one turn alone over the bound: its tail, cut on a whole character", () => {
  const text = continueCapsule([row({ kind: "assistant", text: `start ${"日本".repeat(30_000)} end` })], SOURCE, 4096)!;
  expect(new TextEncoder().encode(text).length).toBeLessThanOrEqual(4096);
  expect(text.endsWith(" end")).toBe(true);
  expect(text).not.toContain("�");
});

test("copy reports whether the clipboard took it", async () => {
  const taken: string[] = [];
  expect(await copyContinue("x", { writeText: async (value) => void taken.push(value) })).toBe(true);
  expect(taken).toEqual(["x"]);
  expect(await copyContinue("x", { writeText: () => Promise.reject(new Error("denied")) })).toBe(false);
  expect(await copyContinue("x", undefined)).toBe(false);
});
