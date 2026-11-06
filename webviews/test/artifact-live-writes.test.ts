// l10n-allow-file: recorded tool fixtures, not shipped UI.
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { artifactLiveSource, WrittenArtifactLive } from "../src/agent-session/acpmux/conversation/artifactLive";
import { latestWrittenArtifacts, toolArtifacts } from "../src/agent-session/acpmux/conversation/writtenArtifacts";
import { outputArtifacts } from "../src/agent-session/acpmux/session-info/OutputsSection";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const doc = (text: string) => `<!doctype html>\n<html><body><h1>Release</h1><p>${text}</p></body></html>`;
const write = (id: string, text: string, fields: Partial<Tool> = {}): Tool => ({
  id,
  title: "Write release.html",
  kind: "edit",
  status: "completed",
  diffs: [{ path: "release.html", newText: doc(text) }],
  ...fields,
});
const row = (...tools: Tool[]): AcpmuxRow => ({
  id: `activity-${tools[0]!.id}`,
  version: 1,
  at: 0,
  kind: "activity",
  toolCount: tools.length,
  items: tools.map((tool) => ({ kind: "tool", text: "", tool })),
});
const opened = (tool: Tool) => toolArtifacts(tool)[0]!;

test("an open written file follows a later completed rewrite of the same file", () => {
  const first = write("w1", "Preparing release", { endedAt: 10 });
  const rows = [row(first)];
  const live = artifactLiveSource(opened(first), rows);
  expect(live).toBeInstanceOf(WrittenArtifactLive);
  const before = live!.read(rows).artifact;
  expect(before.code).toBe(doc("Preparing release"));
  expect(before.identity).toBe("file:release.html");

  const after = live!.read([...rows, row(write("w2", "Release ready", { endedAt: 20 }))]).artifact;
  expect(after.code).toBe(doc("Release ready"));
  expect(after.identity).toBe(before.identity);
  expect(after.revision!).toBeGreaterThan(before.revision!);
});

test("a failed, running or other-file write does not replace the open file", () => {
  const first = write("w1", "Preparing release", { endedAt: 10 });
  const live = new WrittenArtifactLive(opened(first), [row(first)]);
  const rows = [
    row(first),
    row(write("w2", "Broken", { status: "failed", endedAt: 20 })),
    row(write("w3", "Half", { status: "in_progress" })),
    row(write("w4", "Other", { endedAt: 30, diffs: [{ path: "other.html", newText: doc("Other") }] })),
  ];
  expect(live.read(rows).artifact.code).toBe(doc("Preparing release"));
});

test("opening an earlier write keeps it; only writes after opening move the panel on", () => {
  const first = write("w1", "Preparing release", { endedAt: 10 });
  const second = write("w2", "Release ready", { endedAt: 20 });
  const rows = [row(first), row(second)];
  const live = new WrittenArtifactLive(opened(first), rows);
  expect(live.read(rows).artifact.code).toBe(doc("Preparing release"));
  const third = write("w3", "Shipped", { endedAt: 30 });
  expect(live.read([...rows, row(third)]).artifact.code).toBe(doc("Shipped"));
});

test("rows replaced on reconnect that end before the shown write never move the preview back", () => {
  const first = write("w1", "Preparing release", { endedAt: 10 });
  const live = new WrittenArtifactLive(opened(first), [row(first)]);
  const second = write("w2", "Release ready", { endedAt: 20 });
  expect(live.read([row(first), row(second)]).artifact.code).toBe(doc("Release ready"));
  const revision = live.read([row(first), row(second)]).artifact.revision;
  // A fresh client's replayed tail holds only the earlier write: the preview stays on the newer one.
  const replay = [row(write("w1", "Preparing release", { endedAt: 10 }))];
  const after = live.read(replay).artifact;
  expect(after.code).toBe(doc("Release ready"));
  expect(after.revision).toBe(revision);
  // A write after the replay still moves it on.
  expect(live.read([...replay, row(write("w3", "Shipped", { endedAt: 30 }))]).artifact.code).toBe(doc("Shipped"));
});

test("concurrent writes: the last completed write wins, not the last row", () => {
  // The first call started first but ended last, so its contents are the file's.
  const slow = write("slow", "Slow, ended last", { startedAt: 1, endedAt: 40 });
  const fast = write("fast", "Fast, ended first", { startedAt: 2, endedAt: 30 });
  const rows = [row(slow), row(fast)];
  expect(latestWrittenArtifacts(rows).get("release.html")!.artifact.code).toBe(doc("Slow, ended last"));
  const outputs = outputArtifacts(rows).filter((item) => item.key === "file:release.html");
  expect(outputs.map((item) => item.artifact.code)).toEqual([doc("Slow, ended last")]);

  const live = new WrittenArtifactLive(opened(fast), [row(fast)]);
  expect(live.read(rows).artifact.code).toBe(doc("Slow, ended last"));
});

test("without end times the later write in the transcript wins", () => {
  const rows = [row(write("a", "First")), row(write("b", "Second"))];
  expect(latestWrittenArtifacts(rows).get("release.html")!.artifact.code).toBe(doc("Second"));
});

test("a disposed source stops following", () => {
  const first = write("w1", "Preparing release", { endedAt: 10 });
  const live = new WrittenArtifactLive(opened(first), [row(first)]);
  live.dispose();
  expect(live.read([row(first), row(write("w2", "Release ready", { endedAt: 20 }))]).artifact.code).toBe(
    doc("Preparing release"),
  );
});
