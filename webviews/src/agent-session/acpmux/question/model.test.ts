import { expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { questionFromPermission, reply, replyParams, selection, type AgentQuestion } from "./model";

// The fixtures the Swift package tests read (Packages/Shared/CmuxAgentQuestion): one contract,
// two ports. `<name>.request.json` is the acpmux permission record, `<name>.json` the question.
const FIXTURES = fileURLToPath(
  new URL("../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/", import.meta.url),
);
const names = fs
  .readdirSync(FIXTURES)
  .filter((file) => file.endsWith(".json") && !file.endsWith(".request.json"))
  .map((file) => file.slice(0, -".json".length))
  .sort();
const readJSON = (file: string) => JSON.parse(fs.readFileSync(FIXTURES + file, "utf8"));
const expected = (name: string): AgentQuestion => readJSON(`${name}.json`);
const request = (name: string) => readJSON(`${name}.request.json`);

/// Compact JSON with sorted keys, like the Swift `AgentQuestionJSON.data()`.
function sortedJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(sortedJSON).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.keys(value)
      .filter((key) => (value as Record<string, unknown>)[key] !== undefined)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${sortedJSON((value as Record<string, unknown>)[key])}`)
      .join(",")}}`;
  return JSON.stringify(value);
}

test("every fixture maps to its expected question", () => {
  expect(names.length).toBeGreaterThanOrEqual(11);
  for (const name of names) {
    const question = expected(name);
    const mapped = questionFromPermission(request(name));
    expect(mapped, name).toBeDefined();
    // Answered and cancelled fixtures share a pending request: copy the recorded state.
    expect(sortedJSON({ ...mapped!, state: question.state }), name).toBe(sortedJSON(question));
  }
});

// Claude Code's AskUserQuestion answer may carry `annotations`: the chosen option's preview tells the
// agent which mockup the person picked ("selected preview: ..."). acpmux checks it and hands the
// agent its own text.
test("a Claude answer sends the chosen option's preview as its annotation", () => {
  const question = expected("pending-with-preview");
  const item = question.items[0]!;
  const tabs = item.options[1]!;
  const sent = reply(question, { selections: { [item.id]: selection([tabs.id]) } });
  expect(sent.annotations).toEqual({ [item.prompt]: { preview: tabs.preview!.text } });
  expect(replyParams(sent).annotations).toEqual(sent.annotations);
});

// The pane relay (AcpmuxPaneMethods+Answers, cmux-agent-pane-policy) refuses an annotation string over
// 65,536 UTF-8 bytes and with it the whole answer, so a longer preview is left out and the answer goes.
test("a preview over the relay's 65,536-byte bound is left out, and the answer still goes", () => {
  const question = expected("pending-with-preview");
  const item = question.items[0]!;
  const tabs = item.options[1]!;
  const sized = (text: string): AgentQuestion => ({
    ...question,
    items: [
      {
        ...item,
        options: item.options.map((o) => (o.id === tabs.id ? { ...o, preview: { ...o.preview!, text } } : o)),
      },
      ...question.items.slice(1),
    ],
  });
  const answer = { selections: { [item.id]: selection([tabs.id]) } };
  // "é" is two UTF-8 bytes: 32,768 of them are exactly the bound, one ASCII byte more is over it.
  const atBound = "é".repeat(32768);
  expect(reply(sized(atBound), answer).annotations).toEqual({ [item.prompt]: { preview: atBound } });
  const over = reply(sized(atBound + "x"), answer);
  expect(over.annotations).toBeUndefined();
  expect(over.answers).toEqual(reply(question, answer).answers);
  expect(reply(sized("x".repeat(65537)), answer).annotations).toBeUndefined();
});

test("an Other answer, a multi-select or an option with no preview sends no annotation", () => {
  const question = expected("pending-with-preview");
  const item = question.items[0]!;
  expect(reply(question, { selections: { [item.id]: selection([], "Something else") } }).annotations).toBeUndefined();
  // Claude Code shows previews only for single-select questions.
  const multi = { ...question, items: [{ ...item, multiSelect: true }] };
  expect(reply(multi, { selections: { [item.id]: selection([item.options[1]!.id]) } }).annotations).toBeUndefined();
  const single = expected("pending-single");
  const first = single.items[0]!;
  expect(reply(single, { selections: { [first.id]: selection([first.options[0]!.id]) } }).annotations).toBeUndefined();
});

test("only Claude Code gets annotations: the Chief's and Codex's answers stay as they were", () => {
  const question = expected("pending-with-preview");
  const item = question.items[0]!;
  const answer = { selections: { [item.id]: selection([item.options[1]!.id]) } };
  for (const harness of ["chief", "codex"] as const) {
    const other = { ...question, source: { ...question.source, harness } };
    expect(reply(other, answer).annotations, harness).toBeUndefined();
  }
});
