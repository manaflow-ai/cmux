import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

test("subagent, messaging, and inbox activity use the shared row and agent tag", () => {
  expect(source("./ActivityLine.tsx")).toContain("TranscriptActivityRow");
  expect(source("../subagents/SubagentDoneLine.tsx")).toContain(
    "TranscriptActivityRow",
  );
  expect(source("./LaneNoticeBatch.tsx")).toContain("TranscriptActivityRow");
  expect(source("./IncomingMessageCard.tsx")).toContain("AgentTag");
  expect(source("../subagents/DisclosureRow.tsx")).toContain("TranscriptActivityRowShell");
  expect(source("../subagents/DisclosureRow.tsx")).toContain("lineClassName");
  expect(source("./AgentMessageRow.tsx")).toContain("AgentTag");
  expect(source("./TranscriptActivityRow.tsx")).toContain(
    "<AgentTag name={name}",
  );
});

test("the shared activity row lights its text on hover and press", () => {
  const css = source("./TranscriptActivityRow.css");
  expect(css).toContain(
    ".cv-agent-activity-row:is(:hover, :active, :focus-visible, :focus-within)",
  );
  expect(source("./AgentTag.css")).toContain(
    ":is(:hover, :focus-visible, :active)",
  );
});
