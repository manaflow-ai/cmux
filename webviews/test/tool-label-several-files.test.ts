// l10n-allow-file: test fixture titles, not shipped UI.
// A call that edits several files keeps a title that says so ("Edit 2 files") instead of naming
// only the first file, but a title that is only a verb or a raw tool id ("Edit", "patch") still
// names its first file, as it did before.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { toolLabel } from "../src/agent-session/acpmux/toolPaths";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const label = (tool: Partial<Tool>) => toolLabel(tool as Tool, "", (line) => line);
const twoFiles = [{ path: "a.ts" }, { path: "b.ts" }];
const patch = "*** Begin Patch\n*** Update File: a.ts\n*** Update File: b.ts\n*** End Patch";

test("an edit of several files keeps a title that counts them", () => {
  expect(label({ title: "Edit 2 files", kind: "edit", locations: twoFiles })).toBe("Edit 2 files");
});

test("a bare verb or tool id over several files names the first file", () => {
  expect(label({ title: "Edit", kind: "edit", status: "in_progress", locations: twoFiles })).toBe("Edit a.ts");
  expect(label({ title: "Read", kind: "read", locations: twoFiles })).toBe("Read a.ts");
  expect(label({ title: "patch", kind: "edit", inputSummary: JSON.stringify({ patchText: patch }) })).toBe(
    "patch a.ts",
  );
});
