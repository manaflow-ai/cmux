import { describe, expect, test } from "bun:test";
import { markMessageSources, readMessageSources, sourceFilePath, type MessageSource } from "./messageSources";
import type { AcpmuxRow } from "./model";

const source: MessageSource = {
  kind: "file",
  uri: "file:///workspace/docs/readme.md",
  title: "readme.md",
  toolCallId: "read-1",
};
const reply = (turnId = "turn-1", segment = "boot.1"): AcpmuxRow => ({
  kind: "assistant",
  id: `assistant-${turnId}.${segment}`,
  turnId,
  version: 3,
  at: 1000,
  text: "Read the document.",
});
const event = (turnId = "turn-1", segment = "boot.1") => ({
  turnId,
  replyId: `${turnId}.${segment}`,
  sources: [source],
});

describe("message source event identity", () => {
  test("attaches only to the stamped reply and leaves its original row untouched", () => {
    const row = reply();
    const marked = markMessageSources(row, event());
    expect(marked?.sources).toEqual([source]);
    expect(marked?.id).toBe(row.id);
    expect(marked?.version).toBe(4);
    expect(row.sources).toBeUndefined();
    expect(row.version).toBe(3);
  });

  test("a late event cannot attach to a later turn or another segment of the same turn", () => {
    expect(markMessageSources(reply("turn-2"), event())).toBeUndefined();
    expect(markMessageSources(reply("turn-1", "boot.2"), event())).toBeUndefined();
    // A replay page may still find the original row after a newer turn has started.
    expect(markMessageSources(reply(), event())?.sources).toEqual([source]);
  });

  test("missing rows, non-replies and inconsistent event identities do not fall back to the last reply", () => {
    expect(markMessageSources(undefined, event())).toBeUndefined();
    expect(markMessageSources({ ...reply(), kind: "user" }, event())).toBeUndefined();
    expect(markMessageSources(reply(), { ...event(), turnId: "turn" })).toBeUndefined();
    expect(markMessageSources(reply(), { ...event(), replyId: "assistant-turn-1.boot.1" })).toBeUndefined();
    expect(markMessageSources(reply(), { ...event(), sources: [] })).toBeUndefined();
  });
});

describe("source links", () => {
  test("decodes absolute file paths without interpreting their encoded hash as a fragment", () => {
    expect(sourceFilePath("file:///workspace/Design%20notes%20%23%C3%A9.md")).toBe("/workspace/Design notes #é.md");
    expect(sourceFilePath("file:///workspace/100%25.md")).toBe("/workspace/100%.md");
  });

  test("rejects remote file authorities, URL suffixes, malformed escapes and control characters", () => {
    for (const uri of [
      "file://remote.example/workspace/a.md",
      "file:///workspace/a.md?download=1",
      "file:///workspace/a.md#section",
      "file:///workspace/%ZZ.md",
      "file:///workspace/%00.md",
      "file:///workspace/%0A.md",
      "https://example.org/a.md",
      "javascript:alert(1)",
      "docs/a.md",
    ])
      expect(sourceFilePath(uri)).toBeUndefined();
  });

  test("unsafe web targets and backlinks never become clickable sources", () => {
    for (const uri of [
      "javascript:alert(1)",
      "data:text/html,hello",
      "//example.org/page",
      "https://user:password@example.org/page",
    ]) {
      expect(readMessageSources([{ ...source, kind: "web", uri }])).toEqual([]);
      const [wiki] = readMessageSources([{ ...source, kind: "wiki", backlink: uri }]);
      expect(wiki.backlink).toBeUndefined();
    }
    const [wiki] = readMessageSources([
      { ...source, kind: "wiki", revision: "abc", backlink: "https://wiki.example.org/backlinks" },
    ]);
    expect(wiki.revision).toBe("abc");
    expect(wiki.backlink).toBe("https://wiki.example.org/backlinks");
  });

  test("rejects malformed source records and bounds a received list", () => {
    expect(readMessageSources(null)).toEqual([]);
    expect(readMessageSources([null, {}, { ...source, toolCallId: "" }, { ...source, kind: "search" }])).toEqual([]);
    expect(readMessageSources(Array.from({ length: 100 }, () => source))).toHaveLength(64);
  });
});
