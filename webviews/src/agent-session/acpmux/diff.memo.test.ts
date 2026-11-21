// A live turn's edited files are read again on every record that lands in the turn (EditedFilesCard,
// App's last edited turn). Each edit is diffed once while its change is the same object, not once per
// tool call: a 50-call burst with 13 edits spent 43 ms in myers before (bench/tool-call-burst.bench.ts).
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "./model";
import { toolFiles } from "./diff";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const edit = (id: string, path: string, oldText: string, newText: string) =>
  ({
    id,
    kind: "edit",
    status: "completed",
    title: `Edit ${path}`,
    diffs: [{ path, oldText, newText }],
  }) as unknown as Tool;

test("an unchanged edit is diffed once, however often its turn is read", () => {
  const first = edit("t1", "/p/a.ts", "a\nb\nc\n", "a\nB\nc\n");
  const second = edit("t2", "/p/b.ts", "x\n", "y\n");
  const before = toolFiles([first]);
  const after = toolFiles([first, second]);
  // The same change: the same edit object, its hunks not built again.
  expect(after.find((file) => file.path === "/p/a.ts")!.edits[0]).toBe(before[0]!.edits[0]!);
  expect(after.find((file) => file.path === "/p/a.ts")!.additions).toBe(1);
  expect(after.find((file) => file.path === "/p/a.ts")!.deletions).toBe(1);
  // A record that changes a call builds a new change, which is diffed anew.
  const changed = edit("t1", "/p/a.ts", "a\nb\nc\n", "a\nB\nC\n");
  const again = toolFiles([changed]);
  expect(again[0]!.edits[0]).not.toBe(before[0]!.edits[0]!);
  expect(again[0]!.additions).toBe(2);
});
