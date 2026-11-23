// The Stats page's Usage Patterns section (opt-in, cmux-usage-patterns): off says how to turn it
// on, on shows each family's top keys highest first, a paired machine is a count and never its
// opaque key, and an older acpmux's summary (no usagePatterns) draws no section.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createStrings } from "../src/pages/shared/i18n";
import { mockSummary, mockUsagePatterns } from "../src/pages/stats/mockProvider";
import { usageGroups } from "../src/pages/stats/shape";
import { UsageSection } from "../src/pages/stats/StatsPage";
import table from "../src/pages/stats/generated/strings.json";

const strings = createStrings(table, ["en"]);
const NOON = Date.UTC(2026, 9, 12, 12);

test("usage groups keep the page's family order, top keys first, and hide machine ids", () => {
  const patterns = mockUsagePatterns("on", NOON)!;
  const groups = usageGroups(patterns.rollup.counts, 3);
  expect(groups.map((group) => group.family)).toEqual([
    "agent-chat",
    "agent-prompt",
    "tokens",
    "layout",
    "command",
    "operation",
    "connection",
    "acpmux-connection",
    "machine",
    "client",
  ]);
  const command = groups.find((group) => group.family === "command")!;
  expect(command.rows.map((row) => row.key)).toEqual(["select-tab", "new-browser-tab", "new-tab"]);
  expect(command.total).toBe(4120 + 640 + 512 + 395 + 220);
  // A zero count is no row.
  expect(groups.find((group) => group.family === "operation")!.rows.some((row) => row.key === "pane.split")).toBe(
    false,
  );
  const machine = groups.find((group) => group.family === "machine")!;
  expect(machine.distinct).toBe(3);
  expect(machine.rows).toEqual([]);
});

test("off with nothing counted says how to turn it on", () => {
  const html = renderToStaticMarkup(<UsageSection patterns={mockUsagePatterns("off", NOON)!} strings={strings} />);
  expect(html).toContain("Usage Patterns");
  expect(html).toContain("Turn on Record Usage Patterns");
  expect(html).not.toContain("stats-usage-groups");
});

test("on shows the counts, the machines as a number and the connection peak", () => {
  const html = renderToStaticMarkup(<UsageSection patterns={mockUsagePatterns("on", NOON)!} strings={strings} />);
  expect(html).toContain("Claude Code");
  expect(html).toContain("split-right");
  expect(html).toContain("Paired machines");
  expect(html).not.toContain("a1b2c3d4e5f6");
  expect(html).toContain("Most connections open at once");
  expect(html).toContain("17");
  expect(html).not.toContain("Turn on Record Usage Patterns");
});

test("a summary from an older acpmux carries no usage patterns", () => {
  expect(mockSummary("busy", 7, 0, NOON).usagePatterns).toBeUndefined();
  expect(mockUsagePatterns("none", NOON)).toBeUndefined();
});
