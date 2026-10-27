import { expect, test } from "bun:test";
import { OrderedRows } from "../src/agent-session/acpmux/direct";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ArtifactLiveSource } from "../src/agent-session/acpmux/conversation/artifactLive";

const path = "/project/preview.html";
const write = (code: string, status = "completed", file = path, id = "write"): AcpmuxActivity => ({
  kind: "tool",
  text: "Write",
  tool: { id, title: "Write", kind: "edit", status, diffs: [{ path: file, newText: code }] },
});
const row = (id: string, version: number, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version,
  at: 1,
  kind: "activity",
  items,
});
const put = (rows: OrderedRows, next: AcpmuxRow, seq: number) => {
  rows.current = seq;
  rows.set(next.id, next);
  return rows.sorted();
};
const open = (rows: OrderedRows) =>
  new ArtifactLiveSource({ kind: "html", lang: "html", path, code: "<p>First</p>" }, rows.sorted());

test("written previews consume an older concurrent tool completion even when React skips a snapshot", () => {
  const rows = new OrderedRows();
  put(rows, row("old", 1, [write("<p>Second</p>", "in_progress")]), 1);
  put(rows, row("first", 1, [write("<p>First</p>")]), 2);
  for (let i = 0; i < 2000; i++)
    put(rows, { id: `answer-${i}`, version: 1, at: i, kind: "assistant", text: "answer" }, i + 3);
  const source = open(rows);
  put(rows, row("old", 2, [write("<p>Second</p>")]), 2003); // Published, never rendered by React.
  const latest = put(rows, { id: "answer-1999", version: 2, at: 1999, kind: "assistant", text: "More" }, 2004);
  expect(source.read(latest).artifact.code).toBe("<p>Second</p>");
  source.dispose();
  put(rows, row("old", 3, [write("<p>After close</p>")]), 2005);
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Second</p>");
});

test("coalesced tools preserve event order and ignore unrelated, failed and stale writes", () => {
  const rows = new OrderedRows();
  put(rows, row("first", 1, [write("<p>First</p>")]), 1);
  const source = open(rows);
  rows.current = 5;
  rows.set("other", row("other", 1, [write("wrong", "completed", "/else/preview.html")]));
  rows.set("failed", row("failed", 1, [write("failed", "failed")]));
  rows.set(
    "work",
    row("work", 1, [write("<p>Two</p>", "completed", path, "a"), write("pending", "in_progress", path, "b")]),
  );
  rows.current = 6;
  rows.set(
    "work",
    row("work", 2, [write("<p>Two</p>", "completed", path, "a"), write("<p>Three</p>", "completed", path, "b")]),
  );
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Three</p>");
  put(rows, row("stale", 1, [write("old")]), 2);
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Three</p>");
  source.dispose();
});

test("prepend rebuilds reuse unchanged rows, flush once, and keep the preview subscription live", () => {
  const rows = new OrderedRows();
  const current = row("current", 1, [write("<p>First</p>")]);
  put(rows, current, 10);
  const source = open(rows);
  const previous = new Map(rows);
  rows.clear();
  rows.current = 1;
  rows.set("ancient", row("ancient", 1, [write("ancient")]));
  rows.current = 10;
  rows.set("current", { ...current });
  rows.keepSame(previous);
  const page = rows.sorted();
  expect(page[1]).toBe(current);
  expect(source.read(page).artifact.code).toBe("<p>First</p>");
  expect(source.read(page).artifact.revision).toBe(0);
  put(rows, row("current", 2, [write("<p>After page</p>")]), 11);
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>After page</p>");
  source.dispose();
});

test("a completion followed by an output-only update in the same frame is not lost", () => {
  const rows = new OrderedRows();
  put(rows, row("first", 1, [write("<p>First</p>")]), 1);
  const source = open(rows);
  rows.current = 2;
  rows.set("new", row("new", 1, [write("<p>Second</p>")]));
  const output = write("<p>Second</p>");
  output.tool!.output = "done";
  rows.current = 3;
  rows.set("new", row("new", 2, [output]));
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Second</p>");
  source.dispose();
});

test("a fence still updates when a page prepend and new tail arrive together", () => {
  const rows = new OrderedRows();
  const fence = (body: string) => "```markdown\n# Notes\n\n" + body + "\n```";
  put(rows, { id: "fence", version: 1, at: 1, kind: "assistant", text: fence("First") }, 10);
  const source = new ArtifactLiveSource(
    { kind: "markdown", lang: "md", code: "# Notes\n\nFirst", identity: "fence\u00000", revision: 1 },
    rows.sorted(),
  );
  rows.clear();
  put(rows, { id: "older", version: 1, at: 0, kind: "user" }, 1);
  put(rows, { id: "fence", version: 2, at: 1, kind: "assistant", text: fence("Second") }, 10);
  put(rows, { id: "tail", version: 1, at: 2, kind: "assistant" }, 11);
  expect(source.read(rows.sorted()).artifact.code).toContain("Second");
  source.dispose();
});
