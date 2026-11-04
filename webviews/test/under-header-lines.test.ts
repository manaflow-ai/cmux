// A one-tab pane's transcript runs up under the tab row only when nothing sits under the header
// (header/underHeader.ts). A Create Checkpoint review at a one-tab pane's top once stayed under the
// transcript, which took the clicks on its Create and Refresh buttons. Every line App.tsx draws in flow
// under the header is gated by the same record the transcript reads, so a new line cannot be missed.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { anyUnderHeader, runsUnderTabRow, type UnderHeaderLines } from "../src/agent-session/acpmux/header/underHeader";

const none: UnderHeaderLines = {
  checkpointReview: false,
  liveChat: false,
  peerCopy: false,
  watching: false,
  handoffError: false,
};

test("the transcript runs under a solo row only when no line sits under the header", () => {
  expect(runsUnderTabRow(true, none)).toBe(true);
  expect(runsUnderTabRow(false, none)).toBe(false);
  for (const key of Object.keys(none) as (keyof UnderHeaderLines)[]) {
    const lines = { ...none, [key]: true };
    expect(anyUnderHeader(lines)).toBe(true);
    expect(runsUnderTabRow(true, lines)).toBe(false);
  }
});

test("App.tsx gates every line under the header by the record the transcript reads", () => {
  const app = fs.readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/App.tsx"), "utf8");
  expect(app).toContain("const soloUnder = runsUnderTabRow(soloTab, underHeader);");
  expect(app).toContain("checkpointReview: checkpoints.review != null,");
  // The stage's lines between the header and the chat body.
  const start = app.indexOf("{/* A feature tip under its header control");
  const end = app.indexOf("{viewedSandbox ? (", start);
  expect(start).toBeGreaterThan(0);
  expect(end).toBeGreaterThan(start);
  const between = app.slice(start, end);
  // Each top-level conditional there is a line under the header and reads `underHeader.`, except the ones that
  // float over the chat (a feature tip portals out, the summary card is a popover).
  const floating = [
    "!quick && !showNewTab && snapshot.sessionId && <PaneFeatureTips",
    "!sessionInfo.on && !summaryCard.column && summaryPanel",
  ];
  const conditionals = [...between.matchAll(/^ {16}\{(?!\/\*)([^\n]*)/gm)].map((match) => match[1]!);
  expect(conditionals.length).toBeGreaterThan(5);
  for (const line of conditionals) {
    if (floating.some((prefix) => line.startsWith(prefix))) continue;
    if (line.startsWith("<") || line.startsWith("/*")) continue;
    expect(line).toStartWith("underHeader.");
  }
});
