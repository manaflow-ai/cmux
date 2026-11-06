import { expect, test } from "bun:test";
import { toolGroups } from "./conversation/toolGroups";
import { organizationRows } from "./organizationFixture";

test("the organization fixture's run is one group led by its thought, with a thought kept in its place", () => {
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
  expect(groups).toHaveLength(1);
  const [group] = groups;
  if (group?.type !== "group") throw new Error(`expected one group, got ${group?.type}`);
  expect(group.kind).toBe("commands");
  // The leading thought, two steps, the thought between them, then three more steps.
  expect(group.items.map((item) => item.kind)).toEqual(["thought", "tool", "tool", "thought", "tool", "tool", "tool"]);
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
