import { expect, test } from "bun:test";
import { activityGlyph } from "./activityGlyph";
import type { TranscriptEntry } from "./sessionModel";

test("activity glyphs are shared across renderers", () => {
  expect(activityGlyph(activity("command"))).toBe("$");
  expect(activityGlyph(activity("fileChange"))).toBe("+");
  expect(activityGlyph(activity("other"))).toBe("*");
  expect(activityGlyph(activity("command", "failed"))).toBe("!");
});

function activity(
  activityKind: TranscriptEntry["activityKind"],
  activityStatus: TranscriptEntry["activityStatus"] = "completed",
): TranscriptEntry {
  return {
    activityKind,
    activityStatus,
    id: "entry-1",
    isComplete: true,
    role: "activity",
    sessionId: "session-1",
    text: "ran",
  };
}
