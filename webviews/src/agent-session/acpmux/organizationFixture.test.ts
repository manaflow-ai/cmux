import { expect, test } from "bun:test";
import { toolGroups } from "./conversation/toolGroups";
import { organizationRows } from "./organizationFixture";

// Since the 2026-11-14 change a one-file shell read (step 3, `sed -n '1,60p' …`) is a read: it stays
// its own flat row, so it splits the run's commands into two groups.
test("the organization fixture's run leads with its thought, and its one-file read splits its commands", () => {
  const rows = organizationRows(0);
  expect(rows.map((row) => row.kind)).toEqual([
    "user",
    "assistant",
    "questionRecord",
    "plan",
    "activity",
    "assistant",
    "turnSummary",
  ]);
  const run = rows.find((row) => row.kind === "activity")!;
  const groups = toolGroups(run.items ?? []);
  expect(groups.map((group) => group.type)).toEqual(["group", "item", "item", "group"]);
  const [first, , read, last] = groups;
  if (first?.type !== "group" || last?.type !== "group") throw new Error("expected groups around the read");
  expect(first.kind).toBe("commands");
  // The leading thought and two steps; the thought between them keeps its place before the read.
  expect(first.items.map((item) => item.kind)).toEqual(["thought", "tool", "tool"]);
  expect(read?.type === "item" && read.item.tool?.command).toBe("sed -n '1,60p' src/net/fetchWithRetry.test.ts");
  expect(last.kind).toBe("commands");
  expect(last.items.map((item) => item.kind)).toEqual(["tool", "tool"]);
});

test("a thought after a lone call, before a second call of its kind, joins their group", () => {
  const rows = organizationRows(0);
  const items = rows.find((row) => row.kind === "activity")!.items!;
  const [lead, first, second, middle] = items;
  // No thought before the run: the middle thought waits inside the open run and stays in its place.
  const groups = toolGroups([first!, middle!, second!]);
  expect(groups).toHaveLength(1);
  expect(groups[0]?.type === "group" && groups[0].items.map((item) => item.kind)).toEqual(["tool", "thought", "tool"]);
  // A thought with no run open waits to lead the next run; with one call after it, it keeps its own row.
  expect(toolGroups([lead!, first!]).map((group) => group.type)).toEqual(["item", "item"]);
});
