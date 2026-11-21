// l10n-allow-file: test fixtures.
import { describe, expect, test } from "bun:test";
import type { EventRecord } from "../direct";
import { replayFixtureEvents } from "./replayFixture";
import {
  DEFAULT_REPLAY_SPEED,
  REPLAY_SPEEDS,
  replayTimeline,
  seqAt,
  shownPath,
  touchedFiles,
  touchesThrough,
} from "./timeline";

const update = (seq: number, at: number, fields: Record<string, unknown>): EventRecord => ({
  seq,
  at,
  dir: "in",
  kind: String(fields.sessionUpdate),
  msg: { method: "session/update", params: { sessionId: "agent-1", update: fields } },
});

describe("replay touches", () => {
  test("the fixture's read, two test runs and edit, at each call's start", () => {
    const timeline = replayTimeline(replayFixtureEvents());
    expect(timeline.touches.map(({ type, verb, text, failed }) => [type, verb, text, failed])).toEqual([
      ["file", "read", "api/client.ts", false],
      ["command", "run", "bun test api/client.test.ts", true],
      ["file", "edit", "api/client.ts", false],
      ["command", "run", "bun test api/client.test.ts", false],
    ]);
    // Each touch sits on its call's first event, so the list grows as the calls start.
    for (const touch of timeline.touches) expect(seqAt(timeline, touch.time)).toBeGreaterThanOrEqual(touch.seq);
    expect(touchesThrough(timeline.touches, 0)).toBe(0);
    expect(touchesThrough(timeline.touches, timeline.touches[1]!.seq)).toBe(2);
    expect(touchesThrough(timeline.touches, Number.MAX_SAFE_INTEGER)).toBe(4);
  });

  test("a command or path that arrives in a later update is listed at the call's start", () => {
    const timeline = replayTimeline([
      update(1, 1000, { sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", status: "pending" }),
      update(2, 1500, { sessionUpdate: "tool_call_update", toolCallId: "a", rawInput: { command: ["git", "status"] } }),
      update(3, 2000, { sessionUpdate: "tool_call", toolCallId: "b", kind: "edit", title: "Write" }),
      update(4, 2100, {
        sessionUpdate: "tool_call_update",
        toolCallId: "b",
        rawInput: { file_path: "/repo/src/a.ts", content: "x" },
      }),
      update(5, 2200, { sessionUpdate: "tool_call", toolCallId: "c", kind: "search", title: "Grep foo" }),
    ]);
    expect(timeline.touches.map(({ seq, text }) => [seq, text])).toEqual([
      [1, "git status"],
      [3, "/repo/src/a.ts"],
    ]);
  });

  test("files list once each, edited once any call changed them", () => {
    const files = touchedFiles(replayTimeline(replayFixtureEvents()).touches);
    expect(files.map(({ path, edited }) => [path, edited])).toEqual([["api/client.ts", true]]);
    expect(files[0]!.last.verb).toBe("edit");
  });

  test("a path inside the chat's folder reads from there", () => {
    expect(shownPath("/repo/src/a.ts", "/repo/")).toBe("src/a.ts");
    expect(shownPath("/repository/a.ts", "/repo")).toBe("/repository/a.ts");
    expect(shownPath("/etc/hosts")).toBe("/etc/hosts");
  });

  test("replay starts at 10×, one of the speeds", () => {
    expect(REPLAY_SPEEDS).toContain(DEFAULT_REPLAY_SPEED);
    expect(DEFAULT_REPLAY_SPEED).toBe(10);
  });
});
