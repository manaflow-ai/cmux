// The chat header draws no rolling summary line ("Tests pass → Open the PR") beside the chat's name
// or in the tab row (https://github.com/manaflow-ai/cmux/issues/51749: the user did not want it, so
// the line, its acpmux `rollingSummary` field and every surface that drew it are gone).
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

// The files that drew the line, mapped it from acpmux's row, or typed it: the header, the pane body that
// lays out the header and its tab-row copy, the row mapping, and the pane's summary model.
test("no header, pane body or summary mapping source draws a chat's rolling summary", () => {
  const root = join(import.meta.dir, "..");
  const files = [
    ...readdirSync(import.meta.dir)
      .filter((name) => /\.(tsx?|css)$/.test(name) && name !== "noChatSummaryLine.test.tsx")
      .map((name) => join("header", name)),
    ...readdirSync(join(root, "pane"))
      .filter((name) => /\.tsx?$/.test(name))
      .map((name) => join("pane", name)),
    "direct.ts",
    join("direct", "queue.ts"),
    "model.ts",
  ];
  const offenders: string[] = [];
  for (const file of files) {
    const source = readFileSync(join(root, file), "utf8");
    for (const marker of ["rollingSummary", "ChatSummaryLine", "acpmux-chat-summary", "data-chat-summary"])
      if (source.includes(marker)) offenders.push(`${file}: ${marker}`);
  }
  expect(files).toContain(join("pane", "PaneBody.tsx"));
  expect(offenders).toEqual([]);
});
