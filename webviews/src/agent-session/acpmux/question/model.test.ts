import { expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { questionFromPermission, type AgentQuestion } from "./model";

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
