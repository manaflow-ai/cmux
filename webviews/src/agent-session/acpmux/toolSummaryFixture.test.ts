import { expect, test } from "bun:test";
import { backgroundCounts } from "./conversation/BackgroundStatusLine";
import { countsFailed, toolGroups } from "./conversation/toolGroups";
import { toolSummaryRows } from "./toolSummaryFixture";

test("the tool-summary fixture's run is one command group with mixed background and failed calls", () => {
  const rows = toolSummaryRows(0);
  expect(rows.map((row) => row.kind)).toEqual(["user", "activity", "assistant"]);
  const groups = toolGroups(rows[1]!.items ?? []);
  expect(groups).toHaveLength(1);
  const [group] = groups;
  if (group?.type !== "group") throw new Error(`expected one group, got ${group?.type}`);
  expect(group.kind).toBe("commands");
  expect(group.items).toHaveLength(7);
  expect(backgroundCounts(group.items)).toEqual({ completed: 2, failed: 1, running: 1 });
  expect(group.items.filter((item) => countsFailed(item.tool!))).toHaveLength(2);
});
