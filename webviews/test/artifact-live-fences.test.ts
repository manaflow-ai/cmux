import { expect, test } from "bun:test";
import { OrderedRows } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ArtifactLiveSource } from "../src/agent-session/acpmux/conversation/artifactLive";

const put = (rows: OrderedRows, next: AcpmuxRow, seq: number) => {
  rows.current = seq;
  rows.set(next.id, next);
  return rows.sorted();
};

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
