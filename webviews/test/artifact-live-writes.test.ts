import { expect, spyOn, test } from "bun:test";
import { AcpmuxDirectClient, OrderedRows, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ArtifactLiveSource } from "../src/agent-session/acpmux/conversation/artifactLive";
import { RowUpdates } from "../src/agent-session/acpmux/rowUpdates";

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

const SESSION = "artifact-reset";
const recordedUpdate = (seq: number, update: Record<string, unknown>): EventRecord => ({
  sessionId: SESSION,
  seq,
  at: seq,
  dir: "in",
  kind: String(update.sessionUpdate),
  msg: { method: "session/update", params: { update } },
});
const writtenUpdate = (seq: number, code: string) =>
  recordedUpdate(seq, {
    sessionUpdate: "tool_call",
    toolCallId: `write-${seq}`,
    title: "Write",
    kind: "edit",
    status: "completed",
    rawInput: { file_path: path, content: code },
  });

test("the direct thought caller passes the changed item index after a large tool row", () => {
  const tools = Array.from({ length: 1000 }, (_, index) =>
    recordedUpdate(index + 1, {
      sessionUpdate: "tool_call",
      toolCallId: `tool-${index}`,
      title: "Read",
      kind: "read",
      status: "in_progress",
    }),
  );
  const thought = (seq: number) =>
    recordedUpdate(seq, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "more" } });
  const client = AcpmuxDirectClient.replay(SESSION, [...tools, thought(1001), thought(1002)], () => {});
  client.seekReplay(1000);
  const set = OrderedRows.prototype.set;
  const changed: (number | undefined)[] = [];
  const observer = spyOn(OrderedRows.prototype, "set").mockImplementation(function (
    this: OrderedRows,
    id,
    next,
    changedItem,
    removedId,
  ) {
    if (next.kind === "activity") changed.push(changedItem);
    return set.call(this, id, next, changedItem, removedId);
  });
  try {
    client.seekReplay(1002);
    expect(changed).toEqual([1000, 1000]);
  } finally {
    observer.mockRestore();
    client.close();
  }
});

test("a same-session reset accepts lower-sequence writes and rejects old producer snapshots", () => {
  const client = AcpmuxDirectClient.replay(SESSION, [writtenUpdate(1000, "<p>First</p>")], () => {});
  client.seekReplay(1000);
  // Exercise the same reset that a changed createdAt invokes, without a network attach.
  const state = client as unknown as {
    rows: OrderedRows;
    resetSessionState(): void;
    reduce(event: EventRecord): void;
  };
  const oldRows = state.rows;
  const oldSnapshot = oldRows.sorted();
  const source = open(oldRows);
  try {
    state.resetSessionState();
    state.reduce(writtenUpdate(1, "<p>Recreated</p>"));
    expect(source.read(state.rows.sorted()).artifact.code).toBe("<p>Recreated</p>");
    put(oldRows, row("late-old", 1, [write("<p>Late old response</p>")]), 1001);
    expect(source.read(oldRows.sorted()).artifact.code).toBe("<p>Recreated</p>");
    expect(source.read(oldSnapshot).artifact.code).toBe("<p>Recreated</p>");
    state.reduce(writtenUpdate(2, "<p>New live write</p>"));
    expect(source.read(state.rows.sorted()).artifact.code).toBe("<p>New live write</p>");
  } finally {
    source.dispose();
    client.close();
  }
});

test("a thought-token update only reads its changed item in a large tool row", () => {
  const producer = new RowUpdates(() => undefined);
  const tools = Array.from({ length: 1000 }, (_, index) =>
    write(`<p>${index}</p>`, "in_progress", path, `tool-${index}`),
  );
  const thought = { kind: "thought", text: "old" } satisfies AcpmuxActivity;
  const nextThought = { ...thought, text: "new" } satisfies AcpmuxActivity;
  let indexedReads = 0;
  const previousItems = new Proxy([...tools, thought], {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) indexedReads += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  const previous = row("thoughts", 1, previousItems);
  const next = row("thoughts", 2, [...tools, nextThought]);
  producer.note(next, 2, previous, tools.length);
  expect(indexedReads).toBeLessThan(10);
});

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

test("dropping an earlier hidden tool cannot promote its shifted completed write over a newer row", () => {
  const rows = new OrderedRows();
  const removed = write("<p>Removed</p>", "completed", path, "removed");
  const shifted = write("<p>Old</p>", "completed", path, "shifted");
  put(rows, row("group", 1, [removed, shifted]), 1);
  const source = open(rows);
  put(rows, row("newer", 1, [write("<p>Newer</p>", "completed", path, "newer")]), 2);
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Newer</p>");
  // dropToolItem removes `removed` and reuses `shifted` at index zero without a changed-item hint.
  put(rows, row("group", 2, [shifted]), 3);
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Newer</p>");
  source.dispose();
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
  put(rows, { id: "fence", version: 2, at: 1, kind: "assistant", text: fence("Second") }, 11);
  put(rows, { id: "tail", version: 1, at: 2, kind: "assistant" }, 12);
  expect(source.read(rows.sorted()).artifact.code).toContain("Second");
  source.dispose();
});

test("a written preview hands cached and replaced producers over once, then consumes every delta", () => {
  const cached = [row("first", 1, [write("<p>First</p>")])];
  const source = new ArtifactLiveSource({ kind: "html", lang: "html", path, code: "<p>First</p>" }, cached);
  const first = new OrderedRows();
  put(first, cached[0]!, 1);
  put(first, row("concurrent", 1, [write("<p>Second</p>")]), 2);
  for (let i = 0; i < 2000; i++) put(first, { id: `tail-${i}`, version: 1, at: i, kind: "assistant" }, i + 3);
  expect(source.read(first.sorted()).artifact.code).toBe("<p>Second</p>");
  put(first, row("concurrent", 2, [write("<p>Third</p>")]), 2003);
  expect(source.read(first.sorted()).artifact.code).toBe("<p>Third</p>");
  const second = new OrderedRows();
  put(second, row("current", 1, [write("<p>Reconnected</p>")]), 2004);
  expect(source.read(second.sorted()).artifact.code).toBe("<p>Reconnected</p>");
  put(first, row("concurrent", 3, [write("<p>Old producer</p>")]), 2005);
  expect(source.read(first.sorted()).artifact.code).toBe("<p>Reconnected</p>");
  put(second, row("current", 2, [write("<p>Live again</p>")]), 2006);
  expect(source.read(second.sorted()).artifact.code).toBe("<p>Live again</p>");
  source.dispose();
});

test("a fence uses event revisions across a bounded-tail rebuild and producer replacement", () => {
  const text = (body: string) => "```markdown\n# Notes\n\n" + body + "\n```";
  const fence = (version: number, body: string): AcpmuxRow => ({
    id: "fence",
    version,
    at: 1,
    kind: "assistant",
    text: text(body),
  });
  const rows = new OrderedRows();
  put(rows, fence(100, "First"), 1000);
  const source = new ArtifactLiveSource(
    { kind: "markdown", lang: "md", code: "# Notes\n\nFirst", identity: "fence\u00000", revision: 100 },
    rows.sorted(),
  );
  rows.clear();
  put(rows, fence(1, "After bounded rebuild"), 1001);
  expect(source.read(rows.sorted()).artifact.code).toContain("After bounded rebuild");
  const next = new OrderedRows();
  put(next, fence(1, "After reconnect"), 1002);
  const connected = source.read(next.sorted()).artifact;
  expect(connected.code).toContain("After reconnect");
  expect(connected.revision).toBeGreaterThan(100);
  put(rows, fence(101, "Late old producer"), 1003);
  expect(source.read(rows.sorted()).artifact.code).toContain("After reconnect");
  put(next, fence(2, "Keeps streaming"), 1004);
  expect(source.read(next.sorted()).artifact.code).toContain("Keeps streaming");
  source.dispose();
});

test("handoff ranks each file write by its content event, not a later unrelated row update", () => {
  const source = new ArtifactLiveSource({ kind: "html", lang: "html", path, code: "<p>First</p>" }, []);
  const rows = new OrderedRows();
  put(rows, row("old-group", 1, [write("<p>Old</p>", "completed", path, "old")]), 1);
  put(rows, row("new-group", 1, [write("<p>Newest</p>", "completed", path, "new")]), 2);
  const outputOnly = write("<p>Old</p>", "completed", path, "old");
  outputOnly.tool!.output = "extra output after the next write";
  put(rows, row("old-group", 2, [outputOnly, write("unrelated", "completed", "/else/file.html", "other")]), 3);
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Newest</p>");
  put(rows, row("old-group", 3, [write("<p>Actually rewritten</p>", "completed", path, "old")]), 4);
  expect(source.read(rows.sorted()).artifact.code).toBe("<p>Actually rewritten</p>");
  source.dispose();
});
