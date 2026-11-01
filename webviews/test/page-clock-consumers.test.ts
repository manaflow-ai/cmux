import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const files = [
  "src/agent-session/acpmux/clock.ts",
  "src/agent-session/acpmux/conversation/ActivityLine.tsx",
  "src/agent-session/acpmux/conversation/WorkingFor.tsx",
  "src/agent-session/acpmux/subagents/SubagentGroup.tsx",
];

test("clock consumers use the page-owned clock and declare no private repeating timer", () => {
  const source = files.map((file) => readFileSync(path.resolve(import.meta.dir, "../", file), "utf8")).join("\n");
  expect(source).toContain("subscribePageMinute");
  expect(source).toContain("usePageNow");
  expect(source).not.toMatch(/setInterval\s*\(/);
  expect(source).not.toMatch(/addEventListener\(\s*["']visibilitychange/);
});
